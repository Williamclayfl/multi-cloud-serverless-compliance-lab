import json
import logging
import os
import re
from typing import Any

import google.auth
from flask import Flask, Response, jsonify, request
from google.auth.transport.requests import AuthorizedSession
from google.cloud import storage

app = Flask(__name__)

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("gcp-compliance-scanner")

PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("GCP_PROJECT_ID", "")
REQUIRED_LABELS = {
    label.strip()
    for label in re.split(r"[,;]", os.getenv("REQUIRED_LABELS", "project;lab-resource;managed-by"))
    if label.strip()
}
INTERNET_RANGES = {"0.0.0.0/0", "::/0"}
SENSITIVE_PORTS = {"22", "3389"}
PUBLIC_MEMBERS = {"allUsers", "allAuthenticatedUsers"}

_storage_client: storage.Client | None = None
_authorized_session: AuthorizedSession | None = None


@app.post("/")
def receive_event() -> Response:
    event = request.get_json(silent=True) or {}
    headers = cloud_event_headers(request.headers)
    proto_payload = event.get("protoPayload") or {}

    service_name = (
        headers.get("serviceName")
        or proto_payload.get("serviceName")
        or "unknown"
    )
    method_name = (
        headers.get("methodName")
        or proto_payload.get("methodName")
        or "unknown"
    )
    resource_name = (
        headers.get("resourceName")
        or proto_payload.get("resourceName")
        or event.get("resource", {}).get("labels", {}).get("resource_name")
        or "unknown"
    )

    emit(
        "COMPLIANCE_SCAN",
        event_id=headers.get("id"),
        event_type=headers.get("type"),
        service_name=service_name,
        method_name=method_name,
        resource_name=resource_name,
    )

    findings: list[dict[str, Any]] = []

    try:
        if service_name == "storage.googleapis.com":
            findings.extend(scan_storage_event(event, method_name, resource_name))
        elif service_name == "compute.googleapis.com":
            findings.extend(scan_compute_event(event, method_name, resource_name))
        else:
            emit(
                "COMPLIANCE_SCAN_SKIPPED",
                service_name=service_name,
                method_name=method_name,
                resource_name=resource_name,
                reason="unsupported_service",
            )
    except Exception as exc:  # Keep Eventarc delivery healthy while logging evidence.
        emit(
            "COMPLIANCE_SCAN_ERROR",
            service_name=service_name,
            method_name=method_name,
            resource_name=resource_name,
            error=str(exc),
        )

    return jsonify({"scanned": True, "finding_count": len(findings), "findings": findings})


@app.get("/healthz")
def healthz() -> Response:
    return jsonify({"status": "ok"})


def scan_storage_event(event: dict[str, Any], method_name: str, resource_name: str) -> list[dict[str, Any]]:
    if method_name not in {"storage.buckets.create", "storage.buckets.update", "storage.setIamPermissions"}:
        return []

    bucket_name = bucket_name_from_storage_event(event, resource_name)
    if not bucket_name:
        emit(
            "COMPLIANCE_SCAN_ERROR",
            service_name="storage.googleapis.com",
            method_name=method_name,
            resource_name=resource_name,
            error="could_not_extract_bucket_name",
        )
        return []

    return scan_storage_bucket(bucket_name, method_name)


def scan_storage_bucket(bucket_name: str, method_name: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    bucket = storage_client().bucket(bucket_name)

    try:
        policy = bucket.get_iam_policy(requested_policy_version=3)
    except Exception as exc:
        emit(
            "COMPLIANCE_SCAN_ERROR",
            resource_type="GCS_BUCKET",
            resource_id=bucket_name,
            event_name=method_name,
            error=str(exc),
        )
        return findings

    public_bindings = []
    for binding in policy.bindings:
        public_members = sorted(PUBLIC_MEMBERS.intersection(set(binding.get("members", []))))
        if public_members:
            public_bindings.append({"role": binding.get("role"), "members": public_members})

    if public_bindings:
        finding = {
            "resource_type": "GCS_BUCKET",
            "resource_id": bucket_name,
            "event_name": method_name,
            "public_bindings": public_bindings,
            "severity": "HIGH",
            "recommendation": "Remove allUsers/allAuthenticatedUsers grants from the bucket IAM policy.",
        }
        emit("COMPLIANCE_VIOLATION", **finding)
        findings.append(finding)

    return findings


def scan_compute_event(event: dict[str, Any], method_name: str, resource_name: str) -> list[dict[str, Any]]:
    if method_name in {
        "v1.compute.firewalls.insert",
        "v1.compute.firewalls.patch",
        "v1.compute.firewalls.update",
        "beta.compute.firewalls.insert",
        "beta.compute.firewalls.patch",
        "beta.compute.firewalls.update",
    }:
        firewall = firewall_name_from_event(event, resource_name)
        if firewall:
            return scan_firewall_rule(firewall, method_name)

    if method_name in {
        "v1.compute.instances.insert",
        "v1.compute.instances.updateNetworkInterface",
        "beta.compute.instances.insert",
        "beta.compute.instances.updateNetworkInterface",
    }:
        instance_ref = instance_ref_from_event(event, resource_name)
        if instance_ref:
            return scan_compute_instance(instance_ref["zone"], instance_ref["instance"], method_name)

    emit(
        "COMPLIANCE_SCAN_SKIPPED",
        service_name="compute.googleapis.com",
        method_name=method_name,
        resource_name=resource_name,
        reason="unsupported_compute_method_or_resource",
    )
    return []


def scan_firewall_rule(firewall_name: str, method_name: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    firewall = compute_get(f"/compute/v1/projects/{PROJECT_ID}/global/firewalls/{firewall_name}")

    direction = firewall.get("direction", "INGRESS")
    source_ranges = set(firewall.get("sourceRanges", []))
    allowed = firewall.get("allowed", [])
    is_internet_open = bool(source_ranges.intersection(INTERNET_RANGES))
    open_ports = sorted(sensitive_ports_from_allowed(allowed))

    if direction == "INGRESS" and is_internet_open and open_ports:
        finding = {
            "resource_type": "GCE_FIREWALL_RULE",
            "resource_id": firewall_name,
            "event_name": method_name,
            "source_ranges": sorted(source_ranges),
            "open_sensitive_ports": open_ports,
            "severity": "HIGH",
            "recommendation": "Restrict inbound SSH/RDP source ranges to sanctioned lab prefixes.",
        }
        emit("COMPLIANCE_VIOLATION", **finding)
        findings.append(finding)

    return findings


def scan_compute_instance(zone: str, instance_name: str, method_name: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    instance = compute_get(f"/compute/v1/projects/{PROJECT_ID}/zones/{zone}/instances/{instance_name}")

    external_ips = []
    for interface in instance.get("networkInterfaces", []):
        for access_config in interface.get("accessConfigs", []):
            nat_ip = access_config.get("natIP")
            if nat_ip:
                external_ips.append(
                    {
                        "network_interface": interface.get("name"),
                        "access_config": access_config.get("name"),
                        "nat_ip": nat_ip,
                    }
                )

    if external_ips:
        finding = {
            "resource_type": "GCE_INSTANCE",
            "resource_id": instance_name,
            "zone": zone,
            "event_name": method_name,
            "external_ips": external_ips,
            "severity": "MEDIUM",
            "recommendation": "Launch lab VMs without external IP addresses unless public access is explicitly required.",
        }
        emit("COMPLIANCE_VIOLATION", **finding)
        findings.append(finding)

    label_finding = missing_labels_finding("GCE_INSTANCE", instance_name, instance.get("labels", {}), method_name)
    if label_finding:
        label_finding["zone"] = zone
        emit("COMPLIANCE_VIOLATION", **label_finding)
        findings.append(label_finding)

    return findings


def cloud_event_headers(headers: Any) -> dict[str, str]:
    result = {}
    for key, value in headers.items():
        if key.lower().startswith("ce-"):
            result[key[3:].lower()] = value
        elif key.lower() in {"serviceName", "methodName", "resourceName"}:
            result[key] = value
    return {
        "id": result.get("id"),
        "type": result.get("type"),
        "serviceName": result.get("servicename") or result.get("serviceName"),
        "methodName": result.get("methodname") or result.get("methodName"),
        "resourceName": result.get("resourcename") or result.get("resourceName"),
    }


def bucket_name_from_storage_event(event: dict[str, Any], resource_name: str) -> str | None:
    candidates = [
        resource_name,
        nested_get(event, "resource.labels.bucket_name"),
        nested_get(event, "protoPayload.resourceName"),
        nested_get(event, "protoPayload.request.bucket.name"),
        nested_get(event, "protoPayload.request.name"),
    ]

    for candidate in candidates:
        if not candidate:
            continue
        match = re.search(r"(?:projects/_/)?buckets/([^/]+)", str(candidate))
        if match:
            return match.group(1)
        if "/" not in str(candidate):
            return str(candidate)
    return None


def firewall_name_from_event(event: dict[str, Any], resource_name: str) -> str | None:
    candidates = [
        resource_name,
        nested_get(event, "protoPayload.resourceName"),
        nested_get(event, "protoPayload.request.name"),
        nested_get(event, "protoPayload.request.firewallResource.name"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        match = re.search(r"/firewalls/([^/]+)$", str(candidate))
        if match:
            return match.group(1)
        if "/" not in str(candidate):
            return str(candidate)
    return None


def instance_ref_from_event(event: dict[str, Any], resource_name: str) -> dict[str, str] | None:
    candidates = [
        resource_name,
        nested_get(event, "protoPayload.resourceName"),
        nested_get(event, "protoPayload.request.name"),
        nested_get(event, "protoPayload.request.instanceResource.name"),
    ]
    zone = (
        nested_get(event, "resource.labels.zone")
        or zone_from_self_link(str(nested_get(event, "protoPayload.request.zone") or ""))
    )

    for candidate in candidates:
        if not candidate:
            continue
        text = str(candidate)
        match = re.search(r"/zones/([^/]+)/instances/([^/]+)$", text)
        if match:
            return {"zone": match.group(1), "instance": match.group(2)}
        if zone and "/" not in text:
            return {"zone": zone, "instance": text}
    return None


def zone_from_self_link(value: str) -> str | None:
    match = re.search(r"/zones/([^/]+)$", value)
    return match.group(1) if match else None


def sensitive_ports_from_allowed(allowed: list[dict[str, Any]]) -> set[str]:
    ports: set[str] = set()
    for rule in allowed:
        protocol = str(rule.get("IPProtocol", "")).lower()
        if protocol not in {"tcp", "all"}:
            continue
        rule_ports = [str(port) for port in rule.get("ports", [])]
        if protocol == "all" or not rule_ports:
            ports.update(SENSITIVE_PORTS)
            continue
        for port in rule_ports:
            ports.update(expand_sensitive_port_match(port))
    return ports


def expand_sensitive_port_match(port_or_range: str) -> set[str]:
    if "-" not in port_or_range:
        return {port_or_range} if port_or_range in SENSITIVE_PORTS else set()

    start_text, end_text = port_or_range.split("-", 1)
    try:
        start = int(start_text)
        end = int(end_text)
    except ValueError:
        return set()

    return {port for port in SENSITIVE_PORTS if start <= int(port) <= end}


def missing_labels_finding(resource_type: str, resource_id: str, labels: dict[str, str], event_name: str) -> dict[str, Any] | None:
    missing = sorted(REQUIRED_LABELS.difference(set(labels or {})))
    if not missing:
        return None
    return {
        "resource_type": resource_type,
        "resource_id": resource_id,
        "event_name": event_name,
        "missing_labels": missing,
        "severity": "LOW",
        "recommendation": "Apply required lab labels for ownership, cost, and evidence filtering.",
    }


def compute_get(path: str) -> dict[str, Any]:
    session = authorized_session()
    response = session.get(f"https://compute.googleapis.com{path}", timeout=20)
    response.raise_for_status()
    return response.json()


def authorized_session() -> AuthorizedSession:
    global _authorized_session
    if _authorized_session is None:
        credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        _authorized_session = AuthorizedSession(credentials)
    return _authorized_session


def storage_client() -> storage.Client:
    global _storage_client
    if _storage_client is None:
        _storage_client = storage.Client(project=PROJECT_ID or None)
    return _storage_client


def nested_get(data: dict[str, Any], dotted_path: str) -> Any:
    current: Any = data
    for part in dotted_path.split("."):
        if not isinstance(current, dict):
            return None
        current = current.get(part)
    return current


def emit(message: str, **fields: Any) -> None:
    print(json.dumps({"message": message, **fields}, default=str, sort_keys=True), flush=True)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))

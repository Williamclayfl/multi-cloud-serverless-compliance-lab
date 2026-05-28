import json
import logging
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
ec2 = boto3.client("ec2")

PUBLIC_GRANTEES = {
    "http://acs.amazonaws.com/groups/global/AllUsers",
    "http://acs.amazonaws.com/groups/global/AuthenticatedUsers",
}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    detail = event.get("detail", {})
    event_name = detail.get("eventName", "Unknown")
    event_source = detail.get("eventSource", "Unknown")

    emit("COMPLIANCE_SCAN", event_source=event_source, event_name=event_name)

    findings: list[dict[str, Any]] = []

    if event_source == "s3.amazonaws.com":
        bucket_name = bucket_name_from_event(detail)
        if bucket_name:
            findings.extend(scan_s3_bucket(bucket_name, event_name))

    if event_source == "ec2.amazonaws.com" and event_name == "RunInstances":
        instance_ids = instance_ids_from_event(detail)
        findings.extend(scan_ec2_instances(instance_ids, event_name))

    return {"scanned": True, "finding_count": len(findings), "findings": findings}


def bucket_name_from_event(detail: dict[str, Any]) -> str | None:
    request = detail.get("requestParameters") or {}
    response = detail.get("responseElements") or {}

    for key in ("bucketName", "bucket"):
        if request.get(key):
            return request[key]

    if response.get("bucketName"):
        return response["bucketName"]

    return None


def instance_ids_from_event(detail: dict[str, Any]) -> list[str]:
    response = detail.get("responseElements") or {}
    instances_set = response.get("instancesSet") or {}
    items = instances_set.get("items") or []
    return [item["instanceId"] for item in items if item.get("instanceId")]


def scan_s3_bucket(bucket_name: str, event_name: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []

    acl_public = bucket_acl_is_public(bucket_name)
    policy_public = bucket_policy_is_public(bucket_name)
    public_access_block = get_public_access_block(bucket_name)

    if acl_public or policy_public:
        finding = {
            "resource_type": "S3_BUCKET",
            "resource_id": bucket_name,
            "event_name": event_name,
            "acl_public": acl_public,
            "policy_public": policy_public,
            "public_access_block": public_access_block,
            "severity": "HIGH",
            "recommendation": "Keep S3 Block Public Access enabled and remove public ACL/policy grants.",
        }
        emit("COMPLIANCE_VIOLATION", **finding)
        findings.append(finding)

    return findings


def bucket_acl_is_public(bucket_name: str) -> bool:
    try:
        acl = s3.get_bucket_acl(Bucket=bucket_name)
    except ClientError as exc:
        emit("COMPLIANCE_SCAN_ERROR", resource_id=bucket_name, error=str(exc))
        return False

    for grant in acl.get("Grants", []):
        grantee = grant.get("Grantee", {})
        if grantee.get("URI") in PUBLIC_GRANTEES:
            return True
    return False


def bucket_policy_is_public(bucket_name: str) -> bool:
    try:
        status = s3.get_bucket_policy_status(Bucket=bucket_name)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code in {"NoSuchBucketPolicy", "NoSuchPolicy"}:
            return False
        emit("COMPLIANCE_SCAN_ERROR", resource_id=bucket_name, error=str(exc))
        return False

    return bool(status.get("PolicyStatus", {}).get("IsPublic"))


def get_public_access_block(bucket_name: str) -> dict[str, Any]:
    try:
        response = s3.get_public_access_block(Bucket=bucket_name)
        return response.get("PublicAccessBlockConfiguration", {})
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code == "NoSuchPublicAccessBlockConfiguration":
            return {"configured": False}
        emit("COMPLIANCE_SCAN_ERROR", resource_id=bucket_name, error=str(exc))
        return {"configured": "unknown"}


def scan_ec2_instances(instance_ids: list[str], event_name: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    if not instance_ids:
        return findings

    try:
        response = ec2.describe_instances(InstanceIds=instance_ids)
    except ClientError as exc:
        emit("COMPLIANCE_SCAN_ERROR", resource_id=",".join(instance_ids), error=str(exc))
        return findings

    for reservation in response.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            instance_id = instance.get("InstanceId")
            for mapping in instance.get("BlockDeviceMappings", []):
                ebs = mapping.get("Ebs") or {}
                if ebs and ebs.get("Encrypted") is False:
                    finding = {
                        "resource_type": "EC2_INSTANCE",
                        "resource_id": instance_id,
                        "volume_id": ebs.get("VolumeId"),
                        "device_name": mapping.get("DeviceName"),
                        "event_name": event_name,
                        "severity": "HIGH",
                        "recommendation": "Launch EC2 instances with encrypted EBS volumes or enable EBS encryption by default.",
                    }
                    emit("COMPLIANCE_VIOLATION", **finding)
                    findings.append(finding)

    return findings


def emit(message: str, **fields: Any) -> None:
    logger.info(json.dumps({"message": message, **fields}, default=str, sort_keys=True))

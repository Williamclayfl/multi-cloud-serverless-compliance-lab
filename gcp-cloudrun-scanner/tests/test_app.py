import os

os.environ.setdefault("GCP_PROJECT_ID", "test-project")

from app import (  # noqa: E402
    bucket_name_from_storage_event,
    firewall_name_from_event,
    instance_ref_from_event,
    sensitive_ports_from_allowed,
)


def test_bucket_name_from_resource_name():
    assert (
        bucket_name_from_storage_event({}, "projects/_/buckets/example-bucket")
        == "example-bucket"
    )


def test_firewall_name_from_resource_name():
    assert (
        firewall_name_from_event({}, "projects/test/global/firewalls/open-ssh")
        == "open-ssh"
    )


def test_instance_ref_from_resource_name():
    assert instance_ref_from_event(
        {},
        "projects/test/zones/us-east1-b/instances/example-vm",
    ) == {"zone": "us-east1-b", "instance": "example-vm"}


def test_sensitive_port_range_detection():
    allowed = [{"IPProtocol": "tcp", "ports": ["20-25", "3389"]}]
    assert sensitive_ports_from_allowed(allowed) == {"22", "3389"}


def test_all_protocol_means_sensitive_ports_open():
    allowed = [{"IPProtocol": "all"}]
    assert sensitive_ports_from_allowed(allowed) == {"22", "3389"}

# Completion Status

Last checked: June 13, 2026, 9:05 PM ET.

## Project State

The project is portfolio-ready as a multi-cloud serverless compliance lab:

- AWS validates event-driven S3 exposure detection.
- GCP validates event-driven Cloud Storage IAM and firewall exposure detection.
- Azure validates event-driven NSG remediation.
- The AWS EC2 launch gap is documented as an account-verification/provider constraint in `docs/provider-pivot.md`.

## Cleanup And Cost Check

Read-only cleanup checks were run across AWS, GCP, and Azure.

AWS:

- No running, stopped, pending, or stopping lab EC2 instances were found with the project tag filter.
- The AWS scanner stack remains deployed for evidence.
- The CloudTrail S3 bucket remains because CloudTrail delivery depends on it.
- Lab S3 buckets from earlier S3 evidence generation remain. Review and delete them when they are no longer needed.

GCP:

- No Compute Engine VM instances were found.
- No temporary `mc-compliance` firewall rules were found.
- No temporary public IAM test buckets were found.
- Cloud Run service `gcp-compliance-scanner` remains deployed with min instances at the default scale-to-zero behavior.
- Eventarc triggers remain deployed for Storage IAM, Compute firewall, and Compute instance audit events.
- The Cloud Run source staging bucket remains.
- Budget `gcp-lab-monthly-budget` remains configured at 25 USD with current-spend and forecasted-spend thresholds.

Azure:

- Resource group `rg-mc-compliance-lab-eastus` remains for evidence.
- The NSG remediation Function App remains deployed.
- Five lab NSGs remain for evidence.
- NSG rules were checked and are no longer open to `0.0.0.0/0`; they point to the lab placeholder source prefix `203.0.113.10/32`.
- Azure budget guardrails remain configured.

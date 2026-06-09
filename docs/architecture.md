# Architecture

```mermaid
flowchart LR
    subgraph AWS["AWS lab account"]
        S3["S3 bucket API changes"]
        EC2["EC2 RunInstances"]
        CT["CloudTrail management events"]
        EB["EventBridge rule"]
        L["Python Lambda scanner"]
        CW["CloudWatch Logs evidence"]
        S3 --> CT
        EC2 --> CT
        CT --> EB
        EB --> L
        L --> CW
    end

    subgraph GCP["GCP project"]
        GCS["Cloud Storage IAM changes"]
        GCEFW["Compute firewall rule writes"]
        GCEVM["Compute Engine instance creates"]
        CAL["Cloud Audit Logs"]
        EA["Eventarc triggers"]
        CR["Cloud Run scanner"]
        CL["Cloud Logging evidence"]
        GCS --> CAL
        GCEFW --> CAL
        GCEVM --> CAL
        CAL --> EA
        EA --> CR
        CR --> CL
    end

    subgraph Azure["Azure subscription"]
        NSG["NSG security rule writes"]
        AL["Activity Log"]
        AM["Azure Monitor alert"]
        AG["Action Group webhook"]
        AF["PowerShell Azure Function"]
        AI["Application Insights evidence"]
        NSG --> AL
        AL --> AM
        AM --> AG
        AG --> AF
        AF --> NSG
        AF --> AI
    end

    Repo["GitHub portfolio repo"]
    CW --> Repo
    CL --> Repo
    AI --> Repo
```

## Design Intent

This lab demonstrates event-driven compliance detection in AWS and GCP plus active remediation in Azure. It uses serverless services instead of a persistent audit VM to reduce cost and keep the operational surface area small.

## Security Boundaries

- Use a dedicated lab account/project/subscription or dedicated resource groups.
- Use least-privilege runtime identities for Lambda, Cloud Run, Eventarc, and Azure Functions.
- Store only redacted evidence in GitHub.
- Keep public bucket tests, open firewall rules, and open NSG rules limited to intentionally empty or isolated lab resources.
- Destroy or lock down lab resources after evidence is collected.

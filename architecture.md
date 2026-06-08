# Architecture Overview

This document describes the high-level architecture of the Multi-Cloud Serverless Compliance Lab.

## System Architecture

```mermaid
graph TB
    subgraph "Client Layer"
        Web["Web Application"]
        Mobile["Mobile App"]
        CLI["CLI Tool"]
    end

    subgraph "API Gateway Layer"
        APIGateway["API Gateway"]
        Auth["Authentication Service"]
    end

    subgraph "Cloud Providers"
        subgraph "AWS"
            LambdaAWS["Lambda Functions"]
            S3["S3 Storage"]
            DynamoDB["DynamoDB"]
        end

        subgraph "Azure"
            FunctionsAzure["Azure Functions"]
            BlobStorage["Blob Storage"]
            CosmosDB["Cosmos DB"]
        end

        subgraph "Google Cloud"
            CloudFunctions["Cloud Functions"]
            CloudStorage["Cloud Storage"]
            Firestore["Firestore"]
        end
    end

    subgraph "Compliance & Monitoring"
        ComplianceEngine["Compliance Engine"]
        Monitoring["Monitoring & Logging"]
        Audit["Audit Trail"]
    end

    subgraph "Data Layer"
        CentralDB["Central Database"]
        Cache["Cache Layer"]
    end

    Web --> APIGateway
    Mobile --> APIGateway
    CLI --> APIGateway

    APIGateway --> Auth
    APIGateway --> ComplianceEngine

    ComplianceEngine --> LambdaAWS
    ComplianceEngine --> FunctionsAzure
    ComplianceEngine --> CloudFunctions

    LambdaAWS --> S3
    LambdaAWS --> DynamoDB

    FunctionsAzure --> BlobStorage
    FunctionsAzure --> CosmosDB

    CloudFunctions --> CloudStorage
    CloudFunctions --> Firestore

    ComplianceEngine --> CentralDB
    ComplianceEngine --> Monitoring
    ComplianceEngine --> Audit

    CentralDB --> Cache
    Monitoring --> Audit

    style "Client Layer" fill:#e1f5ff
    style "API Gateway Layer" fill:#f3e5f5
    style "AWS" fill:#fff3e0
    style "Azure" fill:#e8f5e9
    style "Google Cloud" fill:#fce4ec
    style "Compliance & Monitoring" fill:#f1f8e9
    style "Data Layer" fill:#ede7f6
```

## Component Descriptions

### Client Layer
- **Web Application**: Browser-based interface for compliance monitoring and management
- **Mobile App**: Native mobile application for on-the-go compliance checks
- **CLI Tool**: Command-line interface for automation and scripting

### API Gateway Layer
- **API Gateway**: Central entry point routing requests to appropriate services
- **Authentication Service**: Manages user authentication and authorization

### Cloud Providers
Each cloud provider hosts serverless compute functions and storage:
- **AWS**: Lambda functions with S3 and DynamoDB
- **Azure**: Azure Functions with Blob Storage and Cosmos DB
- **Google Cloud**: Cloud Functions with Cloud Storage and Firestore

### Compliance & Monitoring
- **Compliance Engine**: Core service orchestrating compliance checks across cloud providers
- **Monitoring & Logging**: Centralized logging and performance monitoring
- **Audit Trail**: Immutable record of all compliance activities

### Data Layer
- **Central Database**: Primary data store for compliance policies and results
- **Cache Layer**: High-performance cache for frequently accessed data

## Data Flow

1. Clients submit requests through the API Gateway
2. Authentication Service validates credentials
3. Compliance Engine orchestrates checks across cloud providers
4. Serverless functions in each cloud provider execute compliance tasks
5. Results are aggregated and stored in the Central Database
6. Monitoring and Audit services record all activities
7. Data is cached for improved performance

## Security Considerations

- All inter-service communication uses encrypted channels
- Authentication and authorization are enforced at the API Gateway
- Compliance data is encrypted at rest and in transit
- Audit trails provide complete traceability
- Multi-cloud architecture ensures no single point of failure

# Architecture

## High-Level Diagram

```
                          ┌──────────────────────────────────────────┐
                          │              AWS Cloud                    │
                          │                                           │
  GitHub                   │  ┌─────────┐       ┌──────────────────┐ │
  Actions  ────deploy────► │  │   ECR   │       │   CloudWatch     │ │
                          │  └────┬────┘       │  ┌────────────┐  │ │
                          │       │             │  │ Dashboards │  │ │
                          │       ▼             │  ├────────────┤  │ │
                          │  ┌─────────┐        │  │  Alarms    │  │ │
                          │  │   ECS   │        │  │  (rollback)│  │ │
                          │  │ ┌─────┐ │        │  └────────────┘  │ │
                          │  │ │Blue │ │        └────────┬─────────┘ │
                          │  │ │Tasks│ │                 │           │
                          │  │ └─────┘ │                 │           │
                          │  │ ┌─────┐ │                 ▼           │
                          │  │ │Green│ │        ┌──────────────────┐ │
                          │  │ │Tasks│ │        │     Lambda       │ │
                          │  │ └─────┘ │        │   (rollback fn)  │ │
                          │  └────┬────┘        └──────────────────┘ │
                          │       │                                    │
              Users ──────┼──►  ┌──────┐                              │
                          │     │ ALB  │                              │
                          │     └──┬───┘                              │
                          │        │                                   │
                          │   ┌────┴────┐       ┌──────┐  ┌──────┐   │
                          │   │  SQS    │       │ SNS  │  │ RDS  │   │
                          │   │ (queues)│◄─────►│(topic│  │(PG)  │   │
                          │   └─────────┘       └──────┘  └──────┘   │
                          └──────────────────────────────────────────┘
```

## Component Diagram

```
                         ┌───────────────────┐
                         │   GitHub Actions   │
                         │   CI/CD Pipeline   │
                         └─────────┬─────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              ┌──────────┐ ┌──────────┐ ┌──────────────┐
              │  Lint &  │ │  Build   │ │   Terraform   │
              │  Test    │ │  Images  │ │   Apply       │
              └──────────┘ └────┬─────┘ └──────┬───────┘
                                │              │
                                ▼              ▼
                         ┌──────────┐  ┌──────────────┐
                         │   ECR    │  │  ECS Cluster  │
                         │ (images) │  │  + ALB + SG   │
                         └──────────┘  └──────┬───────┘
                                              │
                              ┌───────────────┼───────────────┐
                              ▼               ▼               ▼
                       ┌──────────┐   ┌──────────┐   ┌──────────┐
                       │  Flask   │   │  Node    │   │  Spring  │
                       │  App     │   │  App     │   │  App     │
                       │ (monolith)│  │(µsvc #1) │   │(µsvc #2) │
                       └────┬─────┘   └────┬─────┘   └────┬─────┘
                            │              │              │
                            └──────────────┼──────────────┘
                                           │
                              ┌────────────┼────────────┐
                              ▼            ▼            ▼
                         ┌────────┐  ┌────────┐  ┌────────┐
                         │  SQS   │  │  SNS   │  │  RDS   │
                         └────────┘  └────────┘  └────────┘
```

## Data Flow

1. **User request** → ALB → ECS Task (blue or green, depending on active deployment).
2. **Flask App** receives HTTP request, queries/writes **RDS**, publishes events to **SNS**.
3. **Node App** polls **SQS**, processes messages, writes results to **RDS**.
4. **Spring App** subscribes to **SNS**, processes events, stores in **RDS**.

## Deployment Flow (CodeDeploy Blue/Green)

```
main push
    │
    ▼
┌─────────┐    ┌─────────┐    ┌──────────┐    ┌──────────────┐    ┌────────────┐
│  Build  │───►│  Test   │───►│  Push to │───►│  Terraform   │───►│  CodeDeploy│
│  Images │    │ (Floci) │    │   ECR    │    │   Apply      │    │  Create    │
└─────────┘    └─────────┘    └──────────┘    └──────────────┘    │  Deployment│
                                                                    └──────┬─────┘
                                                                           │
       ┌───────────────────────────────────────────────────────────────────┤
       │                    CodeDeploy handles the rest                    │
       │                                                                   │
       ▼                         ▼                         ▼               ▼
┌──────────────┐    ┌──────────────────┐    ┌──────────────┐    ┌──────────────┐
│  Deploy      │───►│  Canary Shift    │───►│  Bake Time    │───►│  Cleanup     │
│  Green Tasks │    │  10% / 5min      │    │  Alarms watch │    │  Blue drained│
└──────────────┘    └───────┬──────────┘    └──────┬───────┘    └──────────────┘
                            │                      │
                            ▼                      ▼
                     ┌──────────────┐      ┌──────────────┐
                     │  Alarm?      │      │  Success?    │
                     │  Auto-roll   │      │  Lambda      │
                     │  back        │      │  notifies    │
                     └──────────────┘      └──────────────┘
```

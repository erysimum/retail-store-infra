# Retail Store Platform — Infrastructure

This Terraform project builds the complete AWS infrastructure for an EKS platform. It creates the VPC, Kubernetes cluster, core add-ons, GitOps setup, and observability tools that everything else runs on. A 5-service retail application runs on top of this platform, but this repository focuses on the foundation that supports it.

`terraform apply` brings up roughly 100 AWS resources in about 15 minutes with no manual steps after the first bootstrap.

What runs on the cluster:

- ArgoCD for GitOps. Every change goes through Git, and the cluster reconciles to match the repos.
- Prometheus, Grafana, Pyrra, and Alertmanager for metrics, dashboards, SLOs, and alerting.
- Istio as the service mesh, also used for fault injection.
- Slack and PagerDuty alerting, routed by severity.

To prove it works end to end I placed a real $10,205 order through the running store and traced the order ID into PostgreSQL.

---

## The four repositories

The project is split across four repos along team lines:

| Repo | What it owns | Who'd own it |
|------|-------------|--------------|
| **[retail-store-infra](https://github.com/erysimum/retail-store-infra)** (this one) | VPC, EKS, ECR, IAM, observability | Platform / Infra |
| **[retail-store-platform](https://github.com/erysimum/retail-store-platform)** | Namespaces, RBAC, NetworkPolicy, ResourceQuota | Platform / Security |
| **[retail-store-gitops](https://github.com/erysimum/retail-store-gitops)** | Helm charts, ArgoCD config, SLOs, dashboards | SRE / DevOps |
| **[retail-store-app](https://github.com/erysimum/retail-store-app)** | App code, CI pipelines, Dockerfiles | App developers |


---

## Architecture

```
Developer commits to the app repo
        │
        ▼
GitHub Actions builds the image and pushes to private ECR 
        │
        ▼
Engineer bumps the Helm values in the gitops repo via PR
        │
        ▼
ArgoCD reconciles the cluster
        │
   ┌────┴──────────────────────────────────────────────┐
   │  UI (Java) ──▶ Catalog (Go)      → MariaDB         │
   │            ──▶ Cart (Java)       → DynamoDB Local  │
   │            ──▶ Checkout (JS)     → Redis           │
   │            ──▶ Orders (Java)     → PostgreSQL      │
   └────────────────────────────────────────────────────┘
   Every service gets an Istio (Envoy) sidecar.
   Metrics go to Prometheus, then Grafana.
   Pyrra turns SLO definitions into alerts, which Alertmanager routes to Slack / PagerDuty.

EKS, 3 worker nodes (t3.large), single NLB ingress via NGINX.
Region: ap-southeast-2 (Sydney).
```

---

## The Terraform modules

Eleven modules under `terraform/modules/`, each with its own `main.tf`, `variables.tf`, and `outputs.tf`:

| Module | What it creates |
|--------|-----------------|
| `vpc` | VPC, 3-tier subnets, NAT, IGW |
| `eks` | EKS cluster, managed node groups, security groups |
| `addons` | CoreDNS, kube-proxy, VPC CNI, Pod Identity, EBS CSI, metrics-server |
| `ecr` | Private registries with immutable tags |
| `github-oidc` | OIDC provider and IAM role for GitHub Actions |
| `argocd` | ArgoCD via Helm |
| `argocd-image-updater` | Image Updater via Helm |
| `ingress` | AWS Load Balancer Controller and NGINX |
| `observability` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| `pyrra` | Pyrra SLO controller |
| `istio` | Istio service mesh (istio-base and istiod) |

---

## Running it

This costs real money, somewhere around $1.50/hour while it's up. Destroy it when you're done.

```bash
# 1. One-time bootstrap: S3 bucket + DynamoDB table for Terraform state
cd terraform/bootstrap
terraform init && terraform apply

# 2. Bring up the dev environment
cd ../environments/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 3. Point kubectl at the cluster
aws eks update-kubeconfig --region ap-southeast-2 --name retail-store-dev

# 4. Hand off to ArgoCD
kubectl apply -f ~/projects/retail-store/retail-store-gitops/argocd/platform-app-dev.yaml
kubectl apply -f ~/projects/retail-store/retail-store-gitops/argocd/apps-appset-dev.yaml
kubectl apply -f ~/projects/retail-store/retail-store-gitops/argocd/observability-app-dev.yaml
```

After about five minutes ArgoCD has all five services and the observability stack reconciled.

Tear down with:

```bash
./destroy.sh
```

The destroy script cleans up the things that block a normal `terraform destroy`: orphaned load balancers, security-group rules that hold the VPC open, and Helm releases stuck in a failed state. I hit all of those by hand once, so they're in the script now.

---

## Walkthrough

### Cluster comes up clean

All seven ArgoCD applications synced and healthy, every service pod running 2/2 (app + sidecar), three nodes Ready on Kubernetes 1.31:

![Cluster healthy](docs/screenshots/01-fresh-cluster-all-services-healthy.PNG)

The same view in the ArgoCD UI. Each app points at the gitops repo on `main`, synced a couple of hours earlier:

![ArgoCD cart and catalog](docs/screenshots/6-argocd1.PNG)
![ArgoCD checkout and observability](docs/screenshots/6-argocd2.PNG)
![ArgoCD orders and platform](docs/screenshots/6-argocd3.PNG)
![ArgoCD ui](docs/screenshots/6-argocd4.PNG)

Sidecar injection is on for every app namespace:

![Istio injection enabled](docs/screenshots/04-01-istio-injection-confirmed.PNG)

And Prometheus is scraping all the Envoy sidecars (5/5 up):

![Prometheus targets up](docs/screenshots/05-prometheus-all-up.PNG)
![Prometheus targets up, more](docs/screenshots/05-prometheus-all-up2.PNG)

### The app actually works

The storefront, served through the NLB:

![Homepage](docs/screenshots/02-homepage.PNG)

A real order placed through checkout. Order `fe0a36e5-…`, $10,205 (an Aqua Ace GT and an Audio-Illusion Spinner):

![Order placed](docs/screenshots/03-order-placed.PNG)

### The order made it to the database

That same order ID in PostgreSQL, across a normalized schema (`orders`, `order_items`, `shipping_addresses`) joined by foreign keys. Created `2026-06-03`:

![Order persisted](docs/screenshots/04-order-persisted.PNG)
![Order items](docs/screenshots/04-order-items.PNG)

### Load test

Locust running 30 users against the UI. ~15 RPS aggregate:

![Locust](docs/screenshots/05-locust-baseline-traffic.PNG)

The Grafana RED dashboard reads from the mesh. One dashboard, a `$service` dropdown, all five services. UI, catalog, and cart under load:

![Grafana RED ui](docs/screenshots/1-locust-traffic-rps-and-error-on-ui-last30mins.PNG)
![Grafana RED catalog](docs/screenshots/1-locust-traffic-rps-and-error-on-catalog-last30mins.PNG)
![Grafana RED cart](docs/screenshots/1-locust-traffic-rps-and-error-on-cart-last30mins.PNG)

### SLOs in Pyrra

Ten SLOs (availability and latency for each service, plus a system-level one), all on a 1-day window with multi-window burn-rate alerts based on the Google SRE Workbook:

![Pyrra SLOs](docs/screenshots/2-pyrra-after-locust.PNG)
![Pyrra error budget](docs/screenshots/2-pyrra-after-locust1.PNG)

### Alerts in Slack

When a burn-rate alert fires, Alertmanager routes by severity. Warnings go to Slack only; criticals got to Slack and Pagerduty.
![Slack alerts](docs/screenshots/slack-error-alert1.PNG)
![Slack alerts with burn windows](docs/screenshots/slack-error-alert2.PNG)

### Chaos engineering with Istio

I apply a VirtualService that aborts a small percentage of catalog requests with HTTP 500. No code change, no restart. Then I watch where the errors show up in the mesh.

The interesting part is the reporter label. The injected 500s only show up on the `source` side (the calling sidecar), because Istio aborts the request before it reaches the catalog pod. The `destination` reporter never sees them:

![Source reporter 500s](docs/screenshots/7-fault-injection-500-returned-from-source-ie-ui.PNG)
![Reporter breakdown by code](docs/screenshots/7-reporter-source-500-errors.PNG)
![Source generating 500s over 1h](docs/screenshots/7-reporter-source-is-generating-500-errors.PNG)

Querying response codes per service confirms it: UI shows the 500s, catalog shows 400s and 200s but no 500s on the destination side:

![500s per service](docs/screenshots/7-500-error-generated-per-service-so-ui-denerating-500.PNG)
![400s per service](docs/screenshots/7-400-error-generated-per-service-so-catalog-generating-400.PNG)
![400s, ui and catalog](docs/screenshots/7-400-error-generated-per-service-ui-and-catalog-generating-400.PNG)
![Response codes by destination](docs/screenshots/6-catalog-response-code-500-0-times.PNG)
![Catalog 400s, ui 500s](docs/screenshots/6-catalog-returning-400-ui-returning-500.PNG)
![Catalog no 500s over window](docs/screenshots/7-catalog-has-no-500-errors-over-the-window.PNG)
![Catalog 500s over 1h](docs/screenshots/7-no-of-500-errors-on-catalog-over-the-last-one-hour.PNG)

In Pyrra the two SLOs moved in opposite directions. Catalog availability recovered toward 99.97% as fresh healthy traffic refilled the window, while the system-level SLO kept burning budget and fired a critical:

![After fault injection](docs/screenshots/8-after-fault-injection.PNG)
![Catalog availability recovers](docs/screenshots/8-catalog-availability-increases-after-fault-injection.PNG)

---

## Notes from building it

**The first bring-up took 4 hours.** Six separate things needed manual fixes: a Helm release stuck in a failed state, a missing security-group rule for the Istio webhook port, a LimitRange that started rejecting pods once the sidecar pushed them over the limit, and an Alertmanager template that sent blank Slack messages. None of it was written down anywhere. I turned each fix into a Terraform change across nine PRs, and the next bring-up was clean in 15 minutes. Once I'd fixed something by hand twice, I figured the third time should be code.

**The reporter gap was a real head-scratcher.** Pyrra showed catalog availability around 73% while the Grafana panel for the same service showed 100%. The answer was the `source` vs `destination` reporter split above: the source sidecar records failures that the destination never sees.

**Time windows interact with traffic mix in ways that aren't obvious.** Because the SLO windows are short (1 day, for demo visibility), a burst of healthy traffic can dilute a fault faster than the fault erodes the budget.
---

## Known gaps

1. **ArgoCD Image Updater can't auth to private ECR yet.** 
2. **Locust's add-to-cart fails 100%** because the CSRF/session handling for the Spring Boot UI isn't wired up in the test. Real browsers are fine. It adds noise to the baseline error rate.
3. **No TLS in front of the NLB.** Needs cert-manager, Let's Encrypt, and a real domain. 
4. **A couple of latency panels read "No data"** because of a metric-name mismatch I haven't fully chased down.

---

## Roadmap

| Item |
|------|
| Argo Rollouts canary with a Prometheus AnalysisTemplate |
| cert-manager + Let's Encrypt + real domain |
| Distributed tracing (Tempo + OpenTelemetry) |
| Centralized logs (Loki + Promtail) |
| Kiali for the Istio service graph |
| Fix the Image Updater ECR auth |
| Branch protection across all four repos |

---

## Stack

Terraform 1.13 (AWS, Helm, Kubernetes providers). AWS: EKS, VPC, RDS, ECR, IAM, Secrets Manager, NLB. Kubernetes 1.31. ArgoCD 3.x with ApplicationSet. Istio 1.29. Prometheus, Grafana, Alertmanager, Pyrra. Slack and PagerDuty. Locust for load. GitHub Actions with OIDC into AWS. App languages: Java (Spring Boot), Go (Gin), Node.js (NestJS).

---

## License

MIT

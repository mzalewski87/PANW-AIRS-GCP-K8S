# Prisma AIRS on GCP – Webinar Demo
## AI Runtime Security: Network Intercept + API Runtime Intercept

> **Repository:** https://github.com/mzalewski87/GCP-AI-WEBINAR-EN  
> **Deployment guide:** [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  PHASE 1 (our Terraform): Application Infrastructure                 │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  GCP Project                                                    │ │
│  │                                                                 │ │
│  │  airs-app-vpc (10.0.2.0/24) ← Application VPC                   │ │
│  │    ├── GKE Cluster (airs-ai-cluster)                            │ │
│  │    │     ├── ai-chatbot (Network Intercept demo)                │ │
│  │    │     └── api-chatbot (API Runtime Intercept demo)           │ │
│  │    └── Gemini AI API                                            │ │
│  │                                                                 │ │
│  │  + GCS bucket, Log Sink, Cloud Asset API (SCM prerequisites)    │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  PHASE 5 (SCM-generated Terraform): AIRS Firewall + VPC Peering      │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  fw-mgmt-vpc ── Cloud NAT ── FW nic1 (management)               │ │
│  │  fw-untrust-vpc ── Public IPs ── FW nic0 (untrust)              │ │
│  │  fw-trust-vpc ── ILB ── FW nic2 (trust) ←VPC Peering→ App VPC   │ │
│  │  + Tag Collector VM                                             │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## Two AIRS protection modes

| | Network Intercept | API Runtime Intercept |
|---|---|---|
| **Application** | `kubernetes/app/` | `kubernetes/api-chatbot/` |
| **Namespace** | `ai-chatbot` | `ai-api-chatbot` |
| **Mechanism** | AIRS Firewall inspects network traffic | AIRS SDK scans content |
| **Firewall** | Required (SCM-generated TF) | Not required |
| **API key** | Not needed | Required (from SCM) |
| **AI model** | Gemini 2.5 Flash (Google AI API) | Gemini 2.5 Flash (Google AI API) |

## Repository layout

```
GCP-AI-WEBINAR-EN/
├── main.tf                          # Root Terraform (PHASE 1)
├── variables.tf                     # Variables
├── outputs.tf                       # Outputs for SCM
├── terraform.tfvars.example         # Example variables
├── secrets.env.example              # SCM API credentials template (copy to secrets.env, gitignored)
├── versions.tf
│
├── modules/
│   ├── vpc/           # Application VPC (single VPC for GKE, peered with SCM Trust)
│   ├── gke/           # GKE cluster + Workload Identity
│   ├── vertex-ai/     # Artifact Registry + endpoint config
│   └── iam/           # Service Accounts (GKE, AI App)
│
├── kubernetes/
│   ├── app/           # Network Intercept Chatbot (Flask + Gemini AI)
│   ├── api-chatbot/   # API Runtime Intercept Chatbot (Flask + AIRS SDK + Gemini)
│   ├── cni/           # PAN CNI DaemonSet (reference)
│   └── I18N.md        # i18n / language switcher documentation
│
├── scripts/
│   ├── deploy-app.sh            # Deploy both apps (Cloud Build)
│   ├── switch-language.sh       # 🌐 Switch chatbot UI language at runtime (en/pl/...)
│   ├── generate-traffic.sh      # Generate traffic before SCM onboarding
│   ├── diagnose-airs.sh         # 🩺 Read-only diagnostics for the whole stack (run first)
│   ├── reset-firewalls.sh       # 🔄 Reset all VM-Series + TC (quick fix for stuck cert retrieval)
│   ├── patch-scm-terraform.sh   # ⚠️ Patch SCM TF (Cloud NAT on mgmt VPC – only when mgmt has no public IP)
│   ├── fix-routing.sh           # ⚠️ Fix routing (remove bypass route + default route in App VPC)
│   ├── fix-health-check.sh      # ⚠️ Fix external LB health check (2 modes: live infra OR --terraform pre-apply)
│   ├── deploy-tls-decryption.sh # Push AIRS Root CA to GKE (TLS decryption)
│   ├── deploy-cni.sh            # PAN CNI instructions (community helm chart preferred on GKE)
│   ├── fix-fw-trust-sources.sh  # ⚠️ Add Pod/Service CIDR to trust VPC FW rule (after SCM apply) + trust subnet to app VPC
│   ├── fix-untrust-web-ingress.sh  # ⚠️ Open GCP FW untrust on TCP/80,443 from internet (after SCM apply)
│   ├── get-outputs.sh           # Show data for SCM
│   ├── teardown-all.sh          # 🧹 Full teardown (6-step destroy + cleanup) for clean restart
│   └── cleanup.sh               # Remove resources (legacy, prefer teardown-all.sh)
│
└── docs/
    ├── DEPLOYMENT_GUIDE.md            # Complete deployment instructions
    ├── SCM_CONFIGURATION_REQUIRED.md  # SCM configuration for CNI chaining
    ├── TROUBLESHOOTING.md             # 🆘 Concrete symptoms → root cause → fix
    └── ARCHITECTURE_DIAGRAMS.md       # Architecture diagrams
```

## Quick start

```bash
# 0. (Optional) Configure secrets.env – SCM API credentials for diagnostic scripts
cp secrets.env.example secrets.env
# Edit secrets.env (SCM_CLIENT_ID, SCM_CLIENT_SECRET, SCM_TSG_ID)
# Without this file diagnose-airs.sh still works, but section 4 (cert/SCM) is limited

# 1. Infrastructure + SCM prerequisites
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars (project_id, region, zone)
terraform init && terraform apply

# 2. Deploy AI Chatbot apps
#    The script automatically annotates ns ai-chatbot:
#    - paloaltonetworks.com/firewall=pan-fw          (CNI chaining)
#    - paloaltonetworks.com/subnetfirewall=kube-system/bypass-metadata
#                                                     (Workload Identity bypass)
./scripts/deploy-app.sh

# 2a. (Optional) Switch chatbot UI language at runtime
#     Both chatbots ship with an i18n system. Default language is English (en);
#     Polish (pl) is bundled. Translation files: kubernetes/{app,api-chatbot}/i18n/<lang>.json
#     See kubernetes/I18N.md for full details (adding new languages, ConfigMap layout, etc.)
./scripts/switch-language.sh pl   # switch both chatbots to Polish
./scripts/switch-language.sh en   # switch back to English

# 3. Generate traffic (wait ~60 min for log propagation)
./scripts/generate-traffic.sh

# 4. In SCM: onboard the GCP Cloud Account
#    → AI Security → AI Runtime → AI Runtime Firewall → Cloud Account Manager
#    → Provide: Project ID, Bucket Name (COPY from: terraform output scm_onboarding_bucket_name)
#    → ⚠️ DO NOT type it manually! Copy the EXACT value.
#    → Download and apply the SCM onboarding Terraform

# 5. In SCM: Add Protections
#    ⚠️ CHECK: Deployment Profile must be linked to a TSG in CSP!
#    If you see "Finish Setup" in CSP → fix it BEFORE downloading the template.
#    → Select applications, configure firewall
#    → Download and apply the deployment Terraform (security_project + application_project)

# 6. In SCM: configure the firewall (interfaces, zones, NAT, routing)
#    ⚠️ BEFORE Push Config: update content on the firewalls (URL/threat DB)
#       A fresh PAN-OS image has stale content → 'remote-access' validation error
#       See: docs/DEPLOYMENT_GUIDE.md section 7.6.1
#    Configure in order (see docs/DEPLOYMENT_GUIDE.md sections 8.1-8.13):
#    - Zones, Interfaces, Loopbacks, Mgmt Profile, Logical Router (8.1-8.5)
#    - PAN-OS Variables ($ELB, $ILB, $GKENODEIP, $CL_POD, $CL_SVC) (8.6)
#    - NAT Policies: outbound (PODs2Internet) + inbound DNAT (8.7)
#    - Security Policies: allow-inbound-web + allow-health-checks (8.8)
#    → Push Config (tick "Ignore Security Checks" if shown)

# 6b. Open GCP-level FW rule on untrust for user traffic (TCP 80/443 from internet)
#     SCM-generated TF only allows Google ELB health-check ranges → users blocked
./scripts/fix-untrust-web-ingress.sh

# 7. Helm: install container security
#    🔴 PREFER the community helm chart (the SCM chart does NOT work properly on GKE Dataplane V2)
helm repo add r-airs-cni https://rweglarz.github.io/c-airs-helm/
helm repo update
TRUST_ILB=$(gcloud compute forwarding-rules list --project=$PROJECT_ID \
  --filter="region:us-central1 AND IPProtocol=UDP" --format="value(IPAddress)" | head -1)
helm install airs r-airs-cni/airs-cni -n kube-system \
  --set deployTo=gke \
  --set "endpoints[0].ip"=$TRUST_ILB \
  --set "fwtrustcidr=10.1.2.0/24"

# 7b. GCP FW rules: Pod CIDR to trust VPC + trust subnet to app VPC
#     (the first – CNI chaining; the second – DNAT inbound to NodePort)
./scripts/fix-fw-trust-sources.sh

# 7c. Restart ai-chatbot so pan-cni hooks the pods
kubectl rollout restart deployment/ai-chatbot -n ai-chatbot

# 8. API Runtime: create a profile and API key in SCM
kubectl create secret generic airs-api-secret \
  --from-literal=AIRS_API_KEY="YOUR_KEY" -n ai-api-chatbot

# 9. (Optional but recommended) TLS Decryption – full inspection of AI prompts/responses
#    SCM: Decryption Profile + Rule (Source: $CL_POD, Dest: untrust, Decrypt SSL Forward Proxy)
#    Export Root CA from SCM, deploy to GKE:
./scripts/deploy-tls-decryption.sh ~/Downloads/airs-root-ca.pem
#    See: docs/DEPLOYMENT_GUIDE.md section 8.13
```

## Something's broken?

```bash
# 1. Quick diagnostics (read-only) – shows which element of the flow is failing
./scripts/diagnose-airs.sh

# 2. Most common fixes:
./scripts/fix-routing.sh           # routing 0.0.0.0/0 → ILB (on "Disconnected" or timeout)
./scripts/fix-health-check.sh      # external LB UNHEALTHY (port/path bug in SCM TF)
./scripts/fix-fw-trust-sources.sh  # pods in CrashLoop / pod→FW timeout / inbound DNAT timeout
./scripts/fix-untrust-web-ingress.sh # external curl timeout from internet (no GCP FW rule for users)
./scripts/reset-firewalls.sh       # firewall has license but no Device Cert (bootstrap stuck)

# 3. Environment in an undefined state? Clean restart:
./scripts/teardown-all.sh \
  --scm-deployment /path/to/<template>_AIRS_GCP_us-central1_HASH \
  --scm-discovery  /path/to/panw-discovery-TSGID-onboarding/gcp \
  --yes
# Then in the UI:
# - CSP → Deployment Profile → Deactivate firewalls (release credits)
# - ❌ DO NOT delete the SCM folder (e.g. 'gcp-airs') – it preserves config for reuse
#   On the next Add Protections pick the same folder → reuse zones/router/policy

# 4. Full troubleshooting:
# → docs/TROUBLESHOOTING.md
```

## What Terraform automates

| SCM prereq (per official docs) | Status |
|----------------------------------------|--------|
| VPC Flow Logs (5s, 100%, metadata) | ✅ Automatic |
| Data Access Audit Logs (Vertex AI) | ✅ Automatic |
| GCS Bucket for logs | ✅ Automatic |
| Log Router Sink | ✅ Automatic |
| Cloud Asset API | ✅ Automatic |
| GCP Service Identity | ⚠️ Manual: `gcloud beta services identity create` |

## Documentation

📖 **[Full deployment guide → docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)**

### Official Palo Alto Networks documentation

| Topic | URL |
|-------|-----|
| Activation & Onboarding | https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding |
| GCP Onboarding Prerequisites | https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/onboard-and-activate-cloud-account-in-scm/gcp-onboarding-prereq-and-steps/discovery-onboarding-prerequisites-for-gcp |
| Deploy Network Intercept in GCP | https://docs.paloaltonetworks.com/ai-runtime-security/administration/deploy-ai-instances-in-public-clouds-as-a-software/add-ai-instance-for-gcp |
| AIRS Python SDK | https://pan.dev/prisma-airs/api/airuntimesecurity/pythonsdk/ |
| Strata Cloud Manager | https://stratacloudmanager.paloaltonetworks.com |

---

## License

[MIT](LICENSE)

## Author

**Michal Zalewski** — michal@zalewski.cloud

# Prisma AIRS on GCP – Webinar Demo
## AI Runtime Security: Network Intercept + API Runtime Intercept + AI Gateway Intercept

> **Repository:** https://github.com/mzalewski87/PANW-AIRS-GCP-K8S  
> **Deployment guide:** [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)  
> **AI Gateway setup:** [docs/AI_GATEWAY_SETUP.md](docs/AI_GATEWAY_SETUP.md)

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
│  │    │     ├── ai-chatbot  (Network Intercept demo)               │ │
│  │    │     ├── api-chatbot (API Runtime Intercept demo)           │ │
│  │    │     └── gw-chatbot  (AI Gateway Intercept demo + MCP)      │ │
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
│                                                                      │
│  OPTIONAL (no GCP resources): AI Gateway Intercept                   │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │  gw-chatbot ──► Portkey AI Gateway ──► Vertex AI (Claude Haiku) │ │
│  │                   └── Prisma AIRS guardrail (in the model path) │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## Three AIRS protection modes

| | Network Intercept | API Runtime Intercept | AI Gateway Intercept |
|---|---|---|---|
| **Application** | `kubernetes/app/` | `kubernetes/api-chatbot/` | `kubernetes/gw-chatbot/` |
| **Namespace** | `ai-chatbot` | `ai-api-chatbot` | `ai-gw-chatbot` |
| **Mechanism** | AIRS Firewall inspects network traffic | AIRS SDK scans content | AIRS guardrail inside the gateway |
| **Code in the app** | None | SDK calls | None |
| **Firewall** | Required (SCM-generated TF) | Not required | Not required |
| **API key** | Not needed | Required (from SCM) | Required (AIRS + Portkey) |
| **AI model** | `gemini-2.5-flash` (Vertex AI) | `gemini-2.5-flash` (Vertex AI) | `claude-haiku-4-5` (Vertex AI) |
| **Blocks with** | Session drop | SDK verdict `block` | HTTP 446 |
| **Extra** | TLS decryption | — | MCP tools → indirect injection demo |

The third mode needs **no GCP infrastructure at all** — it is a good fallback
demo when the firewall stack is unavailable. Setup:
[docs/AI_GATEWAY_SETUP.md](docs/AI_GATEWAY_SETUP.md).

## Repository layout

```
PANW-AIRS-GCP-K8S/
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
│   ├── gw-chatbot/    # AI Gateway Intercept Chatbot (Flask + MCP server + Portkey)
│   │                  # No scanning code – the AIRS guardrail lives in the gateway
│   ├── cni/           # values-pan-cni.yaml (Helm values) + subnetinfo-bypass.yaml
│   │                  # (REQUIRED CRs, chart ships only the CRD) + reference DaemonSet
│   └── I18N.md        # i18n / language switcher documentation
│
├── scripts/
│   ├── deploy-app.sh            # Deploy both apps (Cloud Build) + AIRS-profile / CNI-node preflight
│   ├── deploy-gw-chatbot.sh     # 🟣 Deploy the AI Gateway chatbot (independent of the FW stack)
│   ├── verify-airs-profile.sh   # 🔴 Run BEFORE deploy-app.sh – a wrong profile fails OPEN (silent)
│   ├── patch-pan-cni-chart.sh   # Add extraNodeSelector to the SCM chart (upstream hardcodes it)
│   ├── switch-language.sh       # 🌐 Switch chatbot UI language at runtime (en/pl/...)
│   ├── generate-traffic.sh      # Generate traffic before SCM onboarding
│   ├── diagnose-airs.sh         # 🩺 Read-only diagnostics for the whole stack (run first)
│   ├── reset-firewalls.sh       # 🔄 Reset all VM-Series + TC (quick fix for stuck cert retrieval)
│   ├── patch-scm-terraform.sh   # ⚠️ Patch SCM TF (Cloud NAT on mgmt VPC – only when mgmt has no public IP)
│   ├── fix-routing.sh           # ⚠️ Fix routing (remove bypass route + default route in App VPC)
│   ├── fix-health-check.sh      # ⚠️ Fix external LB health check (2 modes: live infra OR --terraform pre-apply)
│   ├── deploy-tls-decryption.sh # Push AIRS Root CA to GKE (TLS decryption)
│   ├── deploy-cni.sh            # PAN CNI: GKE-version preflight + ns annotations + SCM/official chart instructions
│   ├── fix-fw-trust-sources.sh  # ⚠️ Add Pod/Service CIDR to trust VPC FW rule (after SCM apply) + trust subnet to app VPC
│   ├── fix-untrust-web-ingress.sh  # ⚠️ Open GCP FW untrust on TCP/80,443 from internet (after SCM apply)
│   ├── get-outputs.sh           # Show data for SCM
│   ├── teardown-all.sh          # 🧹 Full teardown (6-step destroy + cleanup) for clean restart
│   └── cleanup.sh               # Remove resources (legacy, prefer teardown-all.sh)
│
└── docs/
    ├── DEPLOYMENT_GUIDE.md            # Complete deployment instructions
    ├── AI_GATEWAY_SETUP.md            # 🟣 Portkey + AIRS guardrail (third mode) end-to-end
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
# Edit terraform.tfvars – 5 values matter (see DEPLOYMENT_GUIDE § 3.3):
#   project_id, region/zone, allowed_mgmt_cidrs (= your public IP, default is 0.0.0.0/0!),
#   airs_security_profile_name (REQUIRED, no default), airs_api_key
#
# 🔴 Network Intercept pins GKE below 1.35.1-gke.1516000 – pan-cni does not implement
#    the CNI STATUS verb and newer GKE takes every node NotReady. Confirm 1.34 is
#    still offered before applying (see § 3.3a):
gcloud container get-server-config --region=$REGION --project=$PROJECT_ID \
  --format="value(validMasterVersions)" | tr ';' '\n' | grep '^1\.34' | head -1
terraform init && terraform apply

# 1a. Verify the AIRS profile BEFORE deploying – a wrong name is never rejected,
#     scans just return 400 and the app answers with NO inspection (fail-open).
./scripts/verify-airs-profile.sh

# 2. Deploy AI Chatbot apps
#    The script automatically annotates ns ai-chatbot:
#    - paloaltonetworks.com/firewall=pan-fw          (CNI chaining)
#    - paloaltonetworks.com/subnetfirewall=ai-chatbot/bypass-metadata-and-internal
#                                                     (Workload Identity bypass)
#      🔴 The SubnetInfo CR must live in the POD's namespace – pan-cni 4.0.2
#      rejects cross-namespace refs and the pod sandbox fails to create.
./scripts/deploy-app.sh

# 2a. (Optional) Switch chatbot UI language at runtime
#     All chatbots ship with an i18n system. Default language is English (en);
#     Polish (pl) is bundled.
#     Translation files: kubernetes/{app,api-chatbot,gw-chatbot}/i18n/<lang>.json
#     See kubernetes/I18N.md for full details (adding new languages, ConfigMap layout, etc.)
#     Covers all three chatbots; ones that aren't deployed are skipped.
./scripts/switch-language.sh pl   # switch every deployed chatbot to Polish
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
#    ✅ Use the SCM-generated chart = the official PANW prisma-airs-helm chart.
#    🔴 FIRST check the GKE version – pan-cni does NOT implement the CNI STATUS verb,
#       so on GKE >= 1.35.1-gke.1516000 (CNI spec 1.1.0) the install takes EVERY node
#       NotReady. deploy-cni.sh aborts on such clusters. See DEPLOYMENT_GUIDE § 3.3a.
./scripts/deploy-cni.sh            # preflight + namespace annotations

# The chart sits directly in architecture/helm/ (Chart.yaml is there), not in a
# subdirectory. 'endpoints' must be the UDP trust ILB IP (needs ip_protocol=UDP, § 7.5a):
CHART=<unzipped>/architecture/helm
TRUST_ILB=$(gcloud compute forwarding-rules list --project=$PROJECT_ID \
  --filter="region:us-central1 AND IPProtocol=UDP" --format="value(IPAddress)" | head -1)

# 7a. Teach the chart to honour a node selector (upstream hardcodes it) and confine
#     pan-cni to the CNI-capable pool – on a mixed cluster it would otherwise land on
#     1.35+ nodes and take them NotReady. No-op if extraNodeSelector is unset.
./scripts/patch-pan-cni-chart.sh $CHART
# Edit kubernetes/cni/values-pan-cni.yaml: endpoints=$TRUST_ILB, fwtrustcidr, clusterid
helm install ai-runtime-security $CHART -n kube-system \
  --values kubernetes/cni/values-pan-cni.yaml
kubectl get nodes    # all must stay Ready

# 7b. Two REQUIRED post-install steps on GKE Dataplane V2:
#     (1) the chart writes the EndpointSlice with 'conditions: {}' → Cilium won't route
kubectl patch endpointslice pan-ngfw-svc-endpoints -n kube-system --type=json \
  -p='[{"op":"replace","path":"/endpoints/0/conditions","value":{"ready":true,"serving":true,"terminating":false}}]'
#     (2) the chart ships the subnetinfos CRD but NO CR instances → the
#         subnetfirewall annotation dangles and Workload Identity breaks.
#     🔴 The CRs go into ai-chatbot – pan-cni rejects cross-namespace refs.
kubectl apply -f kubernetes/cni/subnetinfo-bypass.yaml

# 7c. GCP FW rules: Pod CIDR to trust VPC + trust subnet to app VPC
#     (the first – CNI chaining; the second – DNAT inbound to NodePort)
./scripts/fix-fw-trust-sources.sh

# 7d. Restart ai-chatbot so pan-cni hooks the pods.
#     Its probes must be exec (127.0.0.1) – once the XDP tunnel is attached, nothing
#     from the node netns reaches the pod IP, so httpGet/tcpSocket probes both fail.
#     kubernetes/app/deployment.yaml already ships them that way.
kubectl rollout restart deployment/ai-chatbot -n ai-chatbot

# 8. API Runtime: create a profile and API key in SCM
kubectl create secret generic airs-api-secret \
  --from-literal=AIRS_API_KEY="YOUR_KEY" -n ai-api-chatbot

# 9. (Optional but recommended) TLS Decryption – full inspection of AI prompts/responses
#    SCM: Decryption Profile + Rule (Source: $CL_POD, Dest: untrust, Decrypt SSL Forward Proxy)
#    Export Root CA from SCM, deploy to GKE:
./scripts/deploy-tls-decryption.sh ~/Downloads/airs-root-ca.pem
#    See: docs/DEPLOYMENT_GUIDE.md section 8.13

# 10. (Optional) AI Gateway Intercept – the third chatbot
#     Independent of everything above: no firewall, no pan-cni, no TLS decrypt.
#     The Prisma AIRS guardrail runs INSIDE the Portkey AI Gateway, so the app
#     itself contains no scanning code at all.
#
#     First configure Portkey (UI only – the workspace key is data-plane and
#     cannot create these objects): AIRS integration → guardrail → Vertex
#     provider → config. Full walkthrough: docs/AI_GATEWAY_SETUP.md
#
#     🔴 Two traps that cost hours, both documented there:
#        - Guardrail "Profile ID" silently OVERRIDES "Profile Name" → clear the ID
#        - No config (pc-***) = requests routed with NO guardrail (silent fail-open)
#
# terraform.tfvars: portkey_api_key + portkey_config_id
./scripts/deploy-gw-chatbot.sh
kubectl port-forward -n ai-gw-chatbot svc/gw-chatbot 8082:80   # → http://127.0.0.1:8082
```

## Before the demo

Run the **pre-demo smoke test** in
[DEPLOYMENT_GUIDE § 11](docs/DEPLOYMENT_GUIDE.md#-pre-demo-smoke-test-run-this-30-min-before-the-webinar)
— seven checks, every one of which has failed silently at least once (source-IP drift,
nodes NotReady, egress bypassing the firewall, TLS decrypt off, wrong AIRS profile).
The apps keep answering in all of those states, so you would only find out on stage.

## Something's broken?

```bash
# 0. Both apps suddenly time out with no error? Your public IP changed – the LB
#    source ranges still pin the old one. Fastest check:
curl -s https://ifconfig.me; echo
kubectl get svc ai-chatbot -n ai-chatbot -o jsonpath='{.spec.loadBalancerSourceRanges}'; echo
#    Different → re-patch both services (and update allowed_mgmt_cidrs in tfvars):
MYIP="$(curl -s https://ifconfig.me)/32"
kubectl patch svc ai-chatbot  -n ai-chatbot     --type=merge -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"$MYIP\"]}}"
kubectl patch svc api-chatbot -n ai-api-chatbot --type=merge -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"$MYIP\"]}}"

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

🟣 **[AI Gateway Intercept setup → docs/AI_GATEWAY_SETUP.md](docs/AI_GATEWAY_SETUP.md)** —
Portkey workspace, AIRS guardrail, Vertex provider, the `pc-***` config, the MCP
server, and the indirect prompt-injection demo.

### Official Palo Alto Networks documentation

| Topic | URL |
|-------|-----|
| Activation & Onboarding | https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding |
| GCP Onboarding Prerequisites | https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/onboard-and-activate-cloud-account-in-scm/gcp-onboarding-prereq-and-steps/discovery-onboarding-prerequisites-for-gcp |
| Deploy Network Intercept in GCP | https://docs.paloaltonetworks.com/ai-runtime-security/administration/deploy-ai-instances-in-public-clouds-as-a-software/add-ai-instance-for-gcp |
| AIRS Python SDK | https://pan.dev/prisma-airs/api/airuntimesecurity/pythonsdk/ |
| Strata Cloud Manager | https://stratacloudmanager.paloaltonetworks.com |
| Portkey AI Gateway (AI Gateway Intercept) | https://portkey.ai/docs/ |

---

## License

[MIT](LICENSE)

## Author

**Michal Zalewski** — michal@zalewski.cloud

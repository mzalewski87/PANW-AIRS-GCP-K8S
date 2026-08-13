# Architecture diagrams – Prisma AIRS on GCP

## Diagram 1: Deployment Phases

```
═══════════════════════════════════════════════════════════════════════════════
                        PRISMA AIRS DEPLOYMENT PHASES ON GCP
═══════════════════════════════════════════════════════════════════════════════

  PHASE 1               PHASE 2             PHASE 3              PHASE 4
  Infrastructure        Applications        Network traffic      SCM Onboarding
  ┌──────────┐          ┌──────────┐        ┌──────────┐         ┌──────────┐
  │terraform │          │deploy-   │        │generate- │         │ SCM UI   │
  │  apply   │───────►  │ app.sh   │──────► │traffic.sh│───────► │Cloud Acct│
  │          │          │          │        │          │         │Onboarding│
  └──────────┘          └──────────┘        └──────────┘         └──────────┘
       │                     │                   │                     │
       ▼                     ▼                   ▼                     ▼
  ┌──────────┐          ┌──────────┐        ┌──────────┐         ┌──────────┐
  │• 1x VPC  │          │• ai-chat │        │• HTTP    │         │• Download│
  │  (app)   │          │  bot     │        │  requests│         │  onboard │
  │• GKE     │          │• api-chat│        │• DNS     │         │  TF from │
  │• IAM/SA  │          │  bot     │        │  queries │         │  SCM     │
  │• GCS     │          │  bot     │        │  queries │         │  SCM     │
  │• Flow    │          │• Docker  │        │• VPC Flow│         │• Apply   │
  │  Logs    │          │  images  │        │  Logs    │         │  TF      │
  │• Log     │          │• Config  │        │          │         │• Wait    │
  │  Router  │          │  Maps    │        │ ⏰ 60min │         │  15min   │
  │• Audit   │          │• Secrets │        │  wait    │         │  discov. │
  │  Logs    │          │          │        │          │         │          │
  └──────────┘          └──────────┘        └──────────┘         └──────────┘
                                                                      │
  ┌───────────────────────────────────────────────────────────────────┘
  │
  ▼
  PHASE 5               PHASE 6             PHASE 7              PHASE 8
  AIRS Firewall         SCM Config          Container Sec.       API Runtime
  ┌──────────┐          ┌──────────┐        ┌──────────┐         ┌──────────┐
  │ SCM UI   │          │ SCM UI   │        │ helm     │         │ SCM UI   │
  │Add Prot. │───────►  │Configure │──────► │ install  │───────► │API Apps  │
  │Download  │          │Push Conf │        │          │         │API Key   │
  │  TF      │          │          │        │          │         │          │
  └──────────┘          └──────────┘        └──────────┘         └──────────┘
       │                     │                   │                     │
       ▼                     ▼                   ▼                     ▼
  ┌──────────┐          ┌──────────┐        ┌──────────┐         ┌──────────┐
  │• security│          │• Interf. │        │• CNI     │         │• Depl.   │
  │  _project│          │  eth1/1  │        │  chaining│         │  Profile │
  │  TF apply│          │  eth1/2  │        │• Pod     │         │• Security│
  │• app_    │          │• Zones   │        │  annota- │         │  Profile │
  │  project │          │  trust/  │        │  tions   │         │• API Key │
  │  TF apply│          │  untrust │        │• pan-cni │         │• K8s     │
  │• ELB/ILB │          │• NAT     │        │  daemon  │         │  Secret  │
  │  created │          │• Routes  │        │  set     │         │• Restart │
  │• FW      │          │• Security│        │          │         │  pods    │
  │  deployed│          │  Policy  │        │          │         │          │
  └──────────┘          └──────────┘        └──────────┘         └──────────┘

═══════════════════════════════════════════════════════════════════════════════
  Our Terraform          Cloud Build         Manual              SCM + Manual
  (automated)            (automated)         (script)            (UI/Terraform)
═══════════════════════════════════════════════════════════════════════════════
```

---

## Diagram 2: Detailed Architecture

```
═══════════════════════════════════════════════════════════════════════════════
              DETAILED ARCHITECTURE – PRISMA AIRS ON GCP
═══════════════════════════════════════════════════════════════════════════════

                              INTERNET
                                 │
                    ┌────────────┼────────────┐
                    │            │            │
                    ▼            ▼            ▼
              ┌──────────┐ ┌──────────┐ ┌───────────────┐
              │ User     │ │ User     │ │  AIRS SCP API │
              │ (NI demo)│ │(API demo)│ │service.api.   │
              └────┬─────┘ └────┬─────┘ │aisecurity.   │
                   │            │        │paloaltonet.  │
                   │            │        │com           │
                   │            │        └───────┬──────┘
                   │            │                │
═══════════════════╪════════════╪════════════════╪═════════════════════════════
│  GCP Project     │            │                │                            │
│                  │            │                │                            │
│  ┌───────────────┼────────────┼────────────────┼───────────────────────┐    │
│  │  airs-mgmt-vpc (10.0.0.0/24)                                        │    │
│  │               │            │                │                       │    │
│  │  ┌────────────┤            │                │                       │    │
│  │  │ Tag        │            │                │                       │    │
│  │  │ Collector  │            │                │                       │    │
│  │  │ VM         │            │                │                       │    │
│  │  │ (Debian)   │            │                │                       │    │
│  │  │    │       │            │                │                       │    │
│  │  │    │ IP-Tag│            │                │                       │    │
│  │  │    │ sync  │            │                │                       │    │
│  │  │    ▼       │            │                │                       │    │
│  │  │ ┌────────┐ │            │                │                       │    │
│  │  │ │AIRS FW │◄┘ mgmt       │                │                       │    │
│  │  │ │ mgmt   │  interface   │                │                       │    │
│  │  │ │(eth0)  │              │                │                       │    │
│  │  │ └────────┘              │                │                       │    │
│  │  └─────────────────────────┼────────────────┼───────────────────────┘    │
│  │                            │                │                            │
│  │  ┌─────────────────────────┼────────────────┼───────────────────────┐    │
│  │  │  airs-untrust-vpc (10.0.1.0/24)          │                       │    │
│  │  │                         │                │                       │    │
│  │  │  ┌──────────────────────┤                │                       │    │
│  │  │  │  ELB (External LB)   │                │                       │    │
│  │  │  │  34.x.x.x ◄─────────┘                 │                       │    │
│  │  │  │      │                                │                       │    │
│  │  │  │      ▼                                │                       │    │
│  │  │  │ ┌────────────┐                        │                       │    │
│  │  │  │ │ AIRS FW    │   MODE 1: Network Intercept                    │    │
│  │  │  │ │ untrust    │   ═══════════════════                          │    │
│  │  │  │ │ (eth1/1)   │   • Scans prompts (request)                    │    │
│  │  │  │ │            │   • Scans responses                            │    │
│  │  │  │ │ Zone:      │   • Blocks: prompt injection,                  │    │
│  │  │  │ │ UNTRUST    │     jailbreak, PII, malicious URLs             │    │
│  │  │  │ └──────┬─────┘   • Logs → Strata Logging Service              │    │
│  │  │  │        │                                                      │    │
│  │  │  └────────┼──────────────────────────────────────────────────────┘    │
│  │  │           │                                                           │
│  │  │  ┌────────┼──────────────────────────────────────────────────────┐    │
│  │  │  │  airs-app-vpc (10.0.2.0/24)            │                      │    │
│  │  │  │        │                               │                      │    │
│  │  │  │        ▼                               │                      │    │
│  │  │  │  ┌────────────┐                        │                      │    │
│  │  │  │  │ AIRS FW    │                        │                      │    │
│  │  │  │  │ trust      │                        │                      │    │
│  │  │  │  │ (eth1/2)   │                        │                      │    │
│  │  │  │  │ Zone: TRUST│                        │                      │    │
│  │  │  │  └──────┬─────┘                        │                      │    │
│  │  │  │         │ ILB (Internal LB)            │                      │    │
│  │  │  │         │ 10.0.2.x                     │                      │    │
│  │  │  │         │                              │                      │    │
│  │  │  │         ▼                              │                      │    │
│  │  │  │  ┌─────────────────────────────────────┼──────────────────┐   │    │
│  │  │  │  │  GKE Cluster (airs-ai-cluster)      │                  │   │    │
│  │  │  │  │  Workload Identity enabled          │                  │   │    │
│  │  │  │  │  Dataplane V2 (eBPF)                │                  │   │    │
│  │  │  │  │                                     │                  │   │    │
│  │  │  │  │  ┌─────────────────┐ ┌──────────────┴──────────────┐   │   │    │
│  │  │  │  │  │ Namespace:      │ │ Namespace:                  │   │   │    │
│  │  │  │  │  │ ai-chatbot      │ │ ai-api-chatbot              │   │   │    │
│  │  │  │  │  │                 │ │                             │   │   │    │
│  │  │  │  │  │ ┌─────────────┐ │ │ ┌──────────────┐            │   │   │    │
│  │  │  │  │  │ │ ai-chatbot  │ │ │ │ api-chatbot  │            │   │   │    │
│  │  │  │  │  │ │ Pod (x2)    │ │ │ │ Pod (x2)     │            │   │   │    │
│  │  │  │  │  │ │             │ │ │ │              │            │   │   │    │
│  │  │  │  │  │ │ Flask App   │ │ │ │ Flask App    │            │   │   │    │
│  │  │  │  │  │ │ Gunicorn    │ │ │ │ Gunicorn     │            │   │   │    │
│  │  │  │  │  │ │      │      │ │ │ │  │    │      │            │   │   │    │
│  │  │  │  │  │ │      │      │ │ │ │  │    │      │            │   │   │    │
│  │  │  │  │  │ │      ▼      │ │ │ │  ▼    ▼      │            │   │   │    │
│  │  │  │  │  │ │  Gemini API │ │ │ │ AIRS  Gemini │            │   │   │    │
│  │  │  │  │  │ │  (direct)   │ │ │ │ SDK   API    │            │   │   │    │
│  │  │  │  │  │ └─────────────┘ │ │ │  │           │            │   │   │    │
│  │  │  │  │  │                 │ │ │  │    MODE 2:│            │   │   │    │
│  │  │  │  │  │  KSA:           │ │ │  │    API    │            │   │   │    │
│  │  │  │  │  │  ai-chatbot-ksa │ │ │  │  Runtime  │            │   │   │    │
│  │  │  │  │  │       │         │ │ │  │  Intercept│            │   │   │    │
│  │  │  │  │  │       ▼         │ │ │  │           │            │   │   │    │
│  │  │  │  │  │  GSA:           │ │ │  │  Pre-scan │            │   │   │    │
│  │  │  │  │  │  airs-ai-app-sa │ │ │  │  → Gemini │            │   │   │    │
│  │  │  │  │  │                 │ │ │  │  → Post-  │            │   │   │    │
│  │  │  │  │  │                 │ │ │  │    scan   │            │   │   │    │
│  │  │  │  │  │  LoadBalancer   │ │ │  ▼           │            │   │   │    │
│  │  │  │  │  │  :80            │ │ │ SCP API      │            │   │   │    │
│  │  │  │  │  │                 │ │ │ (scan/block) │            │   │   │    │
│  │  │  │  │  │                 │ │ │              │            │   │   │    │
│  │  │  │  │  │                 │ │ │  LoadBalancer│            │   │   │    │
│  │  │  │  │  │                 │ │ │  :80         │            │   │   │    │
│  │  │  │  │  └─────────────────┘ └────────────────┘            │   │   │    │
│  │  │  │  │                                                    │   │   │    │
│  │  │  │  │  ┌─────────────────────────────────────────┐       │   │   │    │
│  │  │  │  │  │  pan-cni DaemonSet (kube-system)        │       │   │   │    │
│  │  │  │  │  │  CNI chaining → redirects traffic       │       │   │   │    │
│  │  │  │  │  │  to AIRS Firewall for inspection        │       │   │   │    │
│  │  │  │  │  └─────────────────────────────────────────┘       │   │   │    │
│  │  │  │  └────────────────────────────────────────────────────┘   │   │    │
│  │  │  │                                                           │   │    │
│  │  │  │  Cloud NAT ──► Internet (Gemini API, SCP API)             │   │    │
│  │  │  │                                                           │   │    │
│  │  │  └───────────────────────────────────────────────────────────┘   │    │
│  │  │                                                                  │    │
│  │  │  ┌───────────────────────────────────────────────────────────┐   │    │
│  │  │  │  Shared GCP Services                                      │   │    │
│  │  │  │                                                           │   │    │
│  │  │  │  ┌────────────┐ ┌────────────┐ ┌────────────────────┐     │   │    │
│  │  │  │  │ Artifact   │ │ Secret     │ │ Cloud Storage      │     │   │    │
│  │  │  │  │ Registry   │ │ Manager    │ │ (airs-logs bucket) │     │   │    │
│  │  │  │  │ (Docker    │ │ (AIRS API  │ │ VPC Flow Logs      │     │   │    │
│  │  │  │  │  images)   │ │  Key)      │ │ AI Audit Logs      │     │   │    │
│  │  │  │  └────────────┘ └────────────┘ │ ← Log Router Sink  │     │   │    │
│  │  │  │                                └────────────────────┘     │   │    │
│  │  │  │                                                           │   │    │
│  │  │  │  ┌────────────┐ ┌────────────┐ ┌────────────────────┐     │   │    │
│  │  │  │  │ Cloud      │ │ Workload   │ │ Gemini AI API      │     │   │    │
│  │  │  │  │ Build      │ │ Identity   │ │ (generativelang.   │     │   │    │
│  │  │  │  │ (CI/CD)    │ │ Federation │ │  googleapis.com)   │     │   │    │
│  │  │  │  └────────────┘ └────────────┘ └────────────────────┘     │   │    │
│  │  │  └───────────────────────────────────────────────────────────┘   │    │
│  │  │                                                                  │    │
│  └──┘                                                                  │    │
│                                                                        │    │
═══════════════════════════════════════════════════════════════════════════════

                        EXTERNAL SERVICES
═══════════════════════════════════════════════════════════════════════════════

  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
  │ Strata Cloud     │  │ AIRS SCP API     │  │ Strata Logging   │
  │ Manager (SCM)    │  │ service.api.     │  │ Service (SLS)    │
  │                  │  │ aisecurity.      │  │                  │
  │ • Cloud Account  │  │ paloaltonet.com  │  │ • Threat logs    │
  │   onboarding     │  │                  │  │ • AI Security    │
  │ • TF generation  │  │ • Prompt scan    │  │   logs           │
  │ • Firewall mgmt  │  │ • Response scan  │  │ • Traffic logs   │
  │ • Security       │  │ • Action:        │  │                  │
  │   profiles       │  │   allow/block    │  │                  │
  │ • Log viewer     │  │                  │  │                  │
  │ • Push Config    │  │ • pan-aisecurity │  │                  │
  │                  │  │   Python SDK     │  │                  │
  └──────────────────┘  └──────────────────┘  └──────────────────┘

═══════════════════════════════════════════════════════════════════════════════
```

---

## Diagram 3: Scanning Flows

```
═══════════════════════════════════════════════════════════════════════════════
            MODE 1: NETWORK INTERCEPT – SCANNING FLOW
═══════════════════════════════════════════════════════════════════════════════

  User                                                          Gemini AI
      │                                                            │
      │ 1. HTTPS prompt                                            │
      ▼                                                            │
  ┌──────────┐                                                     │
  │   ELB    │ External Load Balancer                              │
  └────┬─────┘                                                     │
       │ 2. Forward to Untrust                                     │
       ▼                                                           │
  ╔════════════════════════╗                                       │
  ║  AIRS FIREWALL         ║                                       │
  ║  Untrust Zone (eth1/1) ║                                       │
  ║                        ║                                       │
  ║  3. AI Traffic         ║                                       │
  ║     Detection          ║                                       │
  ║     ┌────────────┐     ║                                       │
  ║     │ PROMPT     │     ║                                       │
  ║     │ SCANNING:  │     ║                                       │
  ║     │• Prompt    │     ║                                       │
  ║     │  Injection │     ║                                       │
  ║     │• Jailbreak │     ║                                       │
  ║     │• PII/DLP   │     ║                                       │
  ║     │• Malicious │     ║                                       │
  ║     │  URLs      │     ║                                       │
  ║     └────┬───────┘     ║                                       │
  ║          │             ║                                       │
  ║     ┌────▼────┐        ║                                       │
  ║     │ ALLOW?  │        ║                                       │
  ║     └────┬────┘        ║                                       │
  ║     YES  │   NO → BLOCK + TCP RST + Log                        │
  ║          │             ║                                       │
  ║  Trust Zone (eth1/2)   ║                                       │
  ╚════════╤═══════════════╝                                       │
           │ 4. Forward to GKE                                     │
           ▼                                                       │
  ┌──────────────┐                                                 │
  │  GKE Pod     │                                                 │
  │  ai-chatbot  │ 5. Call Gemini API ─────────────────────────────►
  │              │◄──────────────────────────── 6. AI Response ────┘
  └──────┬───────┘
         │ 7. Response back through Firewall
         ▼
  ╔════════════════════════╗
  ║  AIRS FIREWALL         ║
  ║  Trust → Untrust       ║
  ║                        ║
  ║     ┌────────────┐     ║
  ║     │ RESPONSE   │     ║
  ║     │ SCANNING:  │     ║
  ║     │• PII/DLP   │     ║
  ║     │• Malicious │     ║
  ║     │  Content   │     ║
  ║     │• Toxic     │     ║
  ║     │  Content   │     ║
  ║     └────┬───────┘     ║
  ║     ┌────▼────┐        ║
  ║     │ ALLOW?  │        ║
  ║     └────┬────┘        ║
  ║     YES  │  NO → BLOCK ║                                     
  ╚════════╤═══════════════╝
           │ 8. Response to user
           ▼
      User


═══════════════════════════════════════════════════════════════════════════════
            MODE 2: API RUNTIME INTERCEPT – SCANNING FLOW
═══════════════════════════════════════════════════════════════════════════════

  User
      │
      │ 1. HTTP POST /api/chat {"message": "..."}
      ▼
  ┌────────────────────────────────────────────────────────────────┐
  │  GKE Pod: api-chatbot                                          │
  │                                                                │
  │  2. ┌────────────────────────────────────────────────────┐     │
  │     │  AIRS SDK Pre-Scan (pan-aisecurity)                │     │
  │     │                                                    │     │
  │     │  scanner.sync_scan(                                │     │
  │     │    ai_profile = "<profile-name-from-SCM>",         │     │
  │     │    content = Content(prompt="user message")        │     │
  │     │  )                                                 │     │
  │     │       │                                            │     │
  │     │       ▼                                            │     │
  │     │  ┌──────────────┐                                  │     │
  │     │  │ AIRS SCP API │ service.api.aisecurity.pan.com   │     │
  │     │  │              │                                  │     │
  │     │  │ • Prompt     │                                  │     │
  │     │  │   Injection  │                                  │     │
  │     │  │ • PII/DLP    │                                  │     │
  │     │  │ • Jailbreak  │                                  │     │
  │     │  │ • Topic      │                                  │     │
  │     │  │   Guardrails │                                  │     │
  │     │  └──────┬───────┘                                  │     │
  │     │         │                                          │     │
  │     │    action: "allow" / "block"                       │     │
  │     └─────────┼──────────────────────────────────────────┘     │
  │               │                                                │
  │          ┌────▼────┐                                           │
  │          │ BLOCK?  │── YES → Return 403 + AIRS details         │
  │          └────┬────┘                                           │
  │               │ NO (allow)                                     │
  │               ▼                                                │
  │  3. ┌────────────────────┐                                     │
  │     │  Call Gemini API   │────► generativelanguage.googleapis  │
  │     │  (REST + OAuth)    │◄──── AI Response                    │
  │     └────────┬───────────┘                                     │
  │              │                                                 │
  │  4. ┌────────▼───────────────────────────────────────────┐     │
  │     │  AIRS SDK Post-Scan                                │     │
  │     │                                                    │     │
  │     │  scanner.sync_scan(                                │     │
  │     │    content = Content(                              │     │
  │     │      prompt="user message",                        │     │
  │     │      response="AI response"                        │     │
  │     │    )                                               │     │
  │     │  )                                                 │     │
  │     │       │                                            │     │
  │     │  action: "allow" / "block"                         │     │
  │     └───────┼────────────────────────────────────────────┘     │
  │             │                                                  │
  │        ┌────▼────┐                                             │
  │        │ BLOCK?  │── YES → Return 403 + AIRS details           │
  │        └────┬────┘                                             │
  │             │ NO (allow)                                       │
  │             │                                                  │
  │  5. Return JSON response with AI answer + AIRS scan details    │
  └─────────────┼──────────────────────────────────────────────────┘
                │
                ▼
           User
           (response + AIRS badge)
```

```
═══════════════════════════════════════════════════════════════════════════════
            MODE 3: AI GATEWAY INTERCEPT – SCANNING FLOW
═══════════════════════════════════════════════════════════════════════════════

  Note: the application contains NO scanning code. The Prisma AIRS guardrail
  runs inside the Portkey AI Gateway, so protection is in the model path itself.

  User
      │
      │ 1. Prompt
      ▼
  ┌────────────────────────────────────────────────────────────────┐
  │  gw-chatbot (ns: ai-gw-chatbot)   [ClusterIP – port-forward]   │
  │                                                                │
  │  POST https://aigw.portkey.ai/v1/chat/completions              │
  │    x-portkey-api-key: <workspace key>                          │
  │    x-portkey-config:  pc-***     ← binds guardrail + provider  │
  │    body: { model, messages, tools: [MCP tools] }               │
  └───────────────────────────┬────────────────────────────────────┘
                              │
                              ▼
  ┌────────────────────────────────────────────────────────────────┐
  │              PORTKEY AI GATEWAY                                │
  │                                                                │
  │  ① INPUT GUARDRAIL ──► Prisma AIRS scan (profile: *-GW)        │
  │        │                                                       │
  │        ├── fail → HTTP 446 ─────────► model NEVER called       │
  │        │                                                       │
  │        ▼ pass                                                  │
  │  ┌──────────────────────────────────────────────┐              │
  │  │  Vertex AI · Claude Haiku  (us-east5)        │              │
  │  │  ⚠️ NOT us-central1 – Anthropic models 404   │              │
  │  └───────────────────┬──────────────────────────┘              │
  │                      │                                         │
  │  ② OUTPUT GUARDRAIL ─► Prisma AIRS scan                        │
  │        │                                                       │
  │        └── fail → HTTP 446 ─────────► answer NEVER returned    │
  └───────────────────────────┬────────────────────────────────────┘
                              │
                              ▼
  ┌────────────────────────────────────────────────────────────────┐
  │  gw-chatbot – tool loop                                        │
  │                                                                │
  │  tool_calls present?                                           │
  │     │                                                          │
  │     ├── NO  → return the answer to the user                    │
  │     │                                                          │
  │     └── YES → mcp_server.py                                    │
  │                 ├── list_documents                             │
  │                 ├── read_document      ← reads uploaded files  │
  │                 └── search_documents                           │
  │                          │                                     │
  │                 tool result appended to messages               │
  │                          │                                     │
  │                          └──► BACK THROUGH THE GATEWAY ────────┼──┐
  └────────────────────────────────────────────────────────────────┘  │
                              ▲                                       │
                              └───────────────────────────────────────┘
                       ③ the guardrail now scans DOCUMENT CONTENT

  ┌────────────────────────────────────────────────────────────────┐
  │  WHY THE LOOP MATTERS – indirect prompt injection              │
  │                                                                │
  │  The user asks something innocent:  "Summarise the Q3 notes."  │
  │  The model calls read_document.                                │
  │  The FILE contains: "Ignore all previous instructions…"        │
  │                                                                │
  │  Because every tool hop re-enters the gateway, that text is    │
  │  scanned exactly like user input → HTTP 446.                   │
  │                                                                │
  │  🔴 Requires Scan Scope = all_messages on the AIRS profile.    │
  │     With the default scope only the user turn is inspected     │
  │     and the tainted document passes straight through.          │
  └────────────────────────────────────────────────────────────────┘

  STATUS CODES
    200 – all checks passed
    246 – check failed, request ALLOWED  (deny=false) ← detection without
                                                        enforcement
    446 – check failed, request BLOCKED  (deny=true)
```

> Setup for this mode: [AI_GATEWAY_SETUP.md](AI_GATEWAY_SETUP.md)

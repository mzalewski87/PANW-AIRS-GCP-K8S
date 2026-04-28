# Troubleshooting – Prisma AIRS on GCP

> Concrete symptoms → root cause → step-by-step fix.
> All scripts in this guide live in: `./scripts/`.

## Table of contents

1. [Quick diagnostics](#1-quick-diagnostics)
2. [Firewall does not retrieve Device Certificate](#2-firewall-does-not-retrieve-device-certificate)
3. [Firewall has cert but is "Disconnected" in SCM](#3-firewall-has-cert-but-is-disconnected-in-scm)
4. [LB backends UNHEALTHY despite correct configuration](#4-lb-backends-unhealthy-despite-correct-configuration)
5. [Pods have no internet egress (timeout)](#5-pods-have-no-internet-egress-timeout)
6. [Chatbot app responds "empty" via external IP](#6-chatbot-app-responds-empty-via-external-ip)
7. [Tag Collector on GCP – documentation contradiction](#7-tag-collector-on-gcp--documentation-contradiction)
8. [Traffic visible in SCM as node IP instead of pod IP](#8-traffic-visible-in-scm-as-node-ip-instead-of-pod-ip)
9. [SSH access to the firewall and useful CLI commands](#9-ssh-access-to-the-firewall-and-useful-cli-commands)
10. [Reset the firewall without losing SCM configuration](#10-reset-the-firewall-without-losing-scm-configuration)
11. [Push Config OK but `is_first_push_done: False` + no config on the firewall](#11-push-config-ok-but-is_first_push_done-false--no-config-on-the-firewall)
12. [Validation Error: 'remote-access' is not a valid reference (URL filtering)](#12-validation-error-remote-access-is-not-a-valid-reference-url-filtering)
13. [Full environment teardown (clean restart)](#13-full-environment-teardown-clean-restart)
14. [Pods in restart loop after namespace annotation + pan-cni install](#14-pods-in-restart-loop-after-namespace-annotation--pan-cni-install)
15. [Pods in CrashLoop after pan-cni install: SCM helm chart broken on GKE Dataplane V2](#15-pods-in-crashloop-after-pan-cni-install-scm-helm-chart-broken-on-gke-dataplane-v2)
16. [Pod→firewall trust 100% packet loss (FW rule blocks pod CIDR)](#16-podfirewall-trust-100-packet-loss-fw-rule-blocks-pod-cidr)
17. [External ELB → firewall → NodePort timeout (app VPC FW blocks trust subnet)](#17-external-elb--firewall--nodeport-timeout-app-vpc-fw-blocks-trust-subnet)
18. [External LB timeout from internet, only health-checks visible in SCM Logs](#18-external-lb-untrust-elb-timeout-from-internet-only-health-checks-visible-in-scm-logs)

---

## 1. Quick diagnostics

```bash
./scripts/diagnose-airs.sh
```

The script checks in a single pass:
- VPC peering App ↔ Trust state
- 0.0.0.0/0 routes in App VPC
- Cloud NAT / public IP on mgmt VPC
- Firewalls: license, Device Cert, SCM connection
- Health checks (port, requestPath)
- Backend services HEALTHY/UNHEALTHY
- GKE: namespace annotations, pan-cni, pod IPs
- Connectivity test from a pod to Gemini and AIRS API

The output gives concrete next steps for each problem.

---

## 2. Firewall does not retrieve Device Certificate

### Symptoms
In `gcloud compute instances get-serial-port-output <fw-name> --zone=<zone>`:
- ✅ `INFO: Successfully installed license key using authcode <CODE>`
- ❌ No `Certificate retrieved successfully` message
- ❌ No `Connected to SCM` message
- Only `DHCP: new ip ...` in a loop

### ⚡ Quick fix: try a reset without destroying

**In practice we have seen that often a firewall reset is enough** – the first
bootstrap can get stuck between `Successfully installed license key` and cert
retrieval without logging an error in the serial console. A reset forces a
fresh bootstrap which usually succeeds.

```bash
# List firewalls
gcloud compute instances list --project=$PROJECT_ID --filter="name~fw-autoscale OR name~tc-vm"

# Reset each one (parallel is OK – each has its own mgmt interface)
for FW in <fw1> <fw2> <tc-vm>; do
  ZONE=$(gcloud compute instances list --project=$PROJECT_ID --filter="name=$FW" --format='value(zone.basename())')
  gcloud compute instances reset $FW --zone=$ZONE --project=$PROJECT_ID &
done
wait

# Wait 5-7 min, check serial console (Successfully installed license key)
# Then SSH + show device-certificate status (see section 9 of this doc)
```

If after the reset the cert is still not retrieved – see the causes below.

### Other root causes (in order of likelihood)

#### a) PIN expired
The Device Certificate PIN has a **limited TTL** (typically 7 days from
generation in CSP). If more time has passed between generating the PIN and
the actual firewall bootstrap, the bootstrap will succeed at license
activation but cert retrieval will return an error which **does NOT appear
in the serial console**.

**Fix:**
1. Log in to CSP: https://support.paloaltonetworks.com
2. Products → Device Certificates
3. Check the PIN status (PIN ID is in `terraform.tfvars` of the SCM template, field `vm-series-auto-registration-pin-id`)
4. If expired → **Generate Registration PIN** (a new one)
5. Save the new `PIN ID` and `PIN Value`
6. In the SCM template directory:
   ```bash
   cd /path/to/<scm-template-dir>/architecture/security_project/
   # Edit terraform.tfvars - update:
   #   vm-series-auto-registration-pin-id    = "NEW_PIN_ID"
   #   vm-series-auto-registration-pin-value = "NEW_PIN_VALUE"
   # (appears in sections: autoscale.fw-autoscale-common.bootstrap_options
   #  and vmseries.tc-vm-01.bootstrap_options)
   ```
7. Recreate the firewalls (force a fresh bootstrap):
   ```bash
   gcloud compute instance-groups managed recreate-instances <PREFIX>-fw-autoscale-common \
     --region=$REGION --project=$PROJECT_ID \
     --instances=<all-fw-instance-names>
   gcloud compute instances reset <PREFIX>-tc-vm-01 \
     --zone=<zone> --project=$PROJECT_ID
   ```
8. Wait 10-15 min, check the serial console of the new instances.

#### b) Missing Cloud NAT / public IP on mgmt VPC
In our SCM template **the mgmt interface has a public IP** (`create_public_ip = true`
in the `network_interfaces` autoscale config). Cloud NAT is **NOT required**.

If you use a different template where mgmt is private only:
```bash
./scripts/patch-scm-terraform.sh /path/to/<scm-template-dir>/architecture/security_project
# Then: terraform apply in security_project
```

Check whether mgmt has a public IP:
```bash
gcloud compute instances describe <fw-name> --zone=<zone> --project=$PROJECT_ID \
  --format="value(networkInterfaces[1].accessConfigs[0].natIP)"
# If it returns an empty string → mgmt without public IP → Cloud NAT needed
```

#### c) Bootstrap config error
Bootstrap started but init-cfg.txt contains bad data (e.g. wrong authcode, plugin-op-commands).

**Diagnostics:**
```bash
# Check init-cfg in SCM terraform.tfvars (bootstrap_options section):
grep -A 20 "bootstrap_options" /path/to/<scm-template-dir>/architecture/security_project/terraform.tfvars
```

Key fields:
- `authcodes` – must match the active deployment profile in CSP
- `dgname` – Device Group name in SCM (must exist)
- `tplname` – template name in SCM
- `panorama-server = "cloud"` (for SCM-managed)
- `plugin-op-commands = "advance-routing:enable"` (for LR routing)
- `mgmt-interface-swap = enable` (CRITICAL: because nic0=untrust, nic1=mgmt)

If you change anything – `terraform apply` in security_project + recreate firewalls.

---

## 3. Firewall has cert but is "Disconnected" in SCM

### Symptoms
The serial console shows `Certificate retrieved successfully`, but in SCM
Workflows → NGFW Setup → Device Management the firewall status is
`Disconnected` or it does not appear at all.

### Root causes

#### a) Deployment Profile not associated with TSG
The most common cause. See: [DEPLOYMENT_GUIDE.md section 2 → Licensing → item 3](DEPLOYMENT_GUIDE.md#2-prerequisites).

**Symptom in CSP:** Deployment Profile status = `Finish Setup`.

**Fix:**
1. CSP → Products → Software/Cloud NGFW Credits → find your Deployment Profile
2. Click **Finish Setup** or **Associate TSG**
3. Pick the TSG that runs your SCM (check in SCM → Settings → Tenant Info)
4. Wait a few minutes → the status will change to `Active`
5. Recreate the firewalls (see section 10)

#### b) DG name mismatch
`bootstrap_options.dgname` in terraform.tfvars must match the folder/Device
Group name in SCM where the firewall is supposed to register.

**Fix:** update `dgname` in terraform.tfvars + recreate the firewalls.

#### c) Telemetry/Cloud Connector in a different region than TSG
Check in CSP: Telemetry region should be `Americas` (or whatever matches your TSG).

---

## 4. LB backends UNHEALTHY despite correct configuration

### Symptoms
```
gcloud compute backend-services get-health <PREFIX>-external-lb \
  --region=$REGION --project=$PROJECT_ID
```
Shows all firewalls as `UNHEALTHY`.

### Root cause #1 (BEFORE SCM configuration)
The firewall does not yet have loopback interfaces configured in SCM
(section 8.3 of DEPLOYMENT_GUIDE). The LB queries the firewall via health
check but the firewall does not respond because:
- The loopback does not exist (interface not configured)
- No `allow-health-checks` Management Profile (HTTP+HTTPS) on the loopback
- No push config

**Fix:** Walk through sections 8.1-8.8 of [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md#8-phase-6--scm-configuration-after-firewall-deployment).

### Root cause #2 (known bug in SCM template generation)
SCM-generated `security_project/terraform.tfvars` (lbs_external block)
contains the **wrong port** for the HTTP health check:
```hcl
http_health_check_port = "443"                       # ← BUG: HTTP on 443 is impossible
http_health_check_request_path = "/php/login.php"    # ← OK, leave as is
```

The path `/php/login.php` IS correct – PA-VM
`interface_management_profile = allow-health-checks` on HTTP/80 responds
with a 302 redirect for that path (web GUI endpoint). Path `/` returns 404
– don't use it. **You should change ONLY the port (443→80).**

### Two fix modes

**Mode 1 – PRE-APPLY (recommended, permanent fix):**
```bash
./scripts/fix-health-check.sh --terraform <path-to-SCM-template-dir>
```
Edits `security_project/terraform.tfvars` BEFORE apply:
- `http_health_check_port = "443"` → `"80"`
- `http_health_check_request_path = "/php/login.php"` – **left alone**, it's correct
- `health_check_port = "443"` (ILB TCP check) – **left alone**, works fine

**Mode 2 – LIVE INFRA (fix after apply):**
```bash
./scripts/fix-health-check.sh                         # auto-detect HC name
./scripts/fix-health-check.sh <template-name>         # explicit name
```
Updates `gcloud compute health-checks update http`:
- port=80, requestPath=/php/login.php, host=""

### Why `/php/login.php` on HTTP/80 (and not `/`)?

`/php/login.php` is the **PA-VM web GUI** endpoint – PA-VM
`interface_management_profile = allow-health-checks` on **HTTP port 80**
responds to that path with a **302 redirect to HTTPS:443/php/login.php**.
GCP LB accepts 200-399 → HEALTHY.

Path `/` on HTTP/80 returns **404** (PA-VM has no root index over HTTP) → UNHEALTHY.

The SCM template had the path right – the only mistake was **port 443 instead
of 80**. The PAN tutorial repo (where path = `/`) used an older PA-VM version
where `/` returned 200 – current PA-VM versions (11.2.11+) require the
specific path `/php/login.php`.

---

## 5. Pods have no internet egress (timeout)

### Symptoms
```bash
kubectl exec -n ai-chatbot <pod> -- curl -m 5 https://generativelanguage.googleapis.com
# → timeout
```

### Root cause
Traffic from the pod → peering 0.0.0.0/0 → Trust VPC → ILB → VM-Series → untrust → internet.
If the **ILB is UNHEALTHY** or **the firewalls are not configured**, the traffic is dropped at the ILB.

### Fix (ordered)
1. `./scripts/diagnose-airs.sh` – identify which element of the flow is broken
2. Repair successive layers from the bottom up:
   - Routes in App VPC: `./scripts/fix-routing.sh`
   - ELB health check: `./scripts/fix-health-check.sh`
   - Firewall registration in SCM (sections 2 and 3 of this doc)
   - SCM config: zones, interfaces, loopbacks, LR, NAT, security policy
   - Push Config in SCM
3. Verify: `gcloud compute backend-services get-health <PREFIX>-internal-lb --region=$REGION` – all HEALTHY
4. Test: `kubectl exec -n ai-chatbot <pod> -- curl -I https://generativelanguage.googleapis.com` should return HTTP 404 (or 405) quickly

---

## 6. Chatbot app responds "empty" via external IP

### Symptoms
```bash
curl http://<chatbot-external-ip>/api/chat -X POST -d '{"message":"hi"}'
# → empty response after a long delay
```

### Root cause
The external LoadBalancer is working (TCP connections accepted), BUT:
- The application in the pod cannot make a call to Gemini API (or AIRS API for api-chatbot)
- Because there is no egress from the pod to the internet

This is the same symptom as [problem #5](#5-pods-have-no-internet-egress-timeout) seen from the user side.

**Fix:** as in section 5.

**Quick test without the application:**
```bash
POD=$(kubectl get pod -n ai-chatbot -l app=ai-chatbot -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ai-chatbot "$POD" -- timeout 5 curl -sko /dev/null -w "%{http_code}\n" -I https://generativelanguage.googleapis.com
# Working firewall → HTTP 404 or 405
# No egress → timeout / no response
```

---

## 7. Tag Collector on GCP – documentation contradiction

### Situation
- PAN release notes (PAN-OS 11.2.10-h2+): "tag collector only harvests IP tags from **AWS and Azure** private K8s clusters. **GCP not supported**."
- BUT: the SCM template (Add Protections wizard) creates a Tag Collector VM for the GCP deployment.

### Explanation

**Tag Collector ≠ CNI chaining**. They are two different mechanisms:

| | CNI chaining (pan-cni daemonset) | Tag Collector (VM) |
|---|---|---|
| Purpose | Tunnels pod traffic to the firewall | Collects K8s labels → tags in SCM for DAG |
| Component | DaemonSet in GKE | Separate VM (n2-standard-4) |
| Required for basic inspection | ✅ YES | ❌ NO |
| GCP support | ✅ Works (Helm install from SCM template) | ❌ Does not work (since PAN-OS 11.2.10-h2+) |

### Consequences
- **CNI chaining IS functional on GCP** – pods with the
  `paloaltonetworks.com/firewall=pan-fw` annotation have their traffic
  tunneled to the firewall, visible in SCM logs as Pod IP (10.100.x.x)
- **Tag Collector VM is deployed but does NOT collect tags** on GCP
- In SCM you will not see K8s labels as IP-tags in policy DAG
- But all other firewall functions (security policy by IP/zone, AI Security Profile, decryption) work normally

### What to do
**Accept the situation**: leave Tag Collector in the deployment (it does no
harm), use security policies based on IP CIDR + zone, not on K8s labels DAG.

---

## 8. Traffic visible in SCM as node IP instead of pod IP

### Symptoms
In SCM Log Viewer → Firewall/Traffic, traffic from the ai-chatbot
application shows source IP = `10.0.2.x` (node IP) instead of `10.100.x.x` (pod IP).

### Root cause
CNI chaining is not working for the given namespace.

### Fix
1. Check the namespace annotation:
   ```bash
   kubectl get namespace ai-chatbot -o jsonpath='{.metadata.annotations.paloaltonetworks\.com/firewall}'
   # Expected: pan-fw
   ```
   If empty:
   ```bash
   kubectl annotate namespace ai-chatbot paloaltonetworks.com/firewall=pan-fw --overwrite
   ```

2. Check the pan-cni daemonset:
   ```bash
   kubectl get daemonset -n kube-system | grep pan-cni
   # Should be DESIRED=CURRENT=READY (e.g. 3/3)
   ```

3. Check the endpoint slice (it should point at the ILB IP):
   ```bash
   kubectl get endpointslice -n kube-system | grep pan
   # Should contain the ILB IP (e.g. 10.1.2.253)
   ```

4. Check `fwtrustcidr` in the helm values:
   ```bash
   helm get values ai-runtime-security -n kube-system | grep fwtrustcidr
   # Should be the Trust VPC subnet (e.g. 10.1.2.0/24)
   ```

5. Restart pods (force CNI re-attach):
   ```bash
   kubectl rollout restart deployment/ai-chatbot -n ai-chatbot
   ```

6. Wait 5-10 min for propagation, check the logs in SCM.

---

## 9. SSH access to the firewall and useful CLI commands

### Connecting
```bash
# Public IP of mgmt interface
MGMT_IP=$(gcloud compute instances describe <fw-name> \
  --zone=<zone> --project=$PROJECT_ID \
  --format="value(networkInterfaces[1].accessConfigs[0].natIP)")

# SSH (the key must match the one given in the SCM template ssh-keys)
ssh -i ~/.ssh/<your-key> admin@$MGMT_IP
```

### Diagnostic CLI commands

```
# Device Certificate status
> show device-certificate status

# Connection status to SCM (cloudmgmt)
> show plugins cloudmgmt cloud-status
> show plugins cloudmgmt all-status

# System logs (cert retrieval, SCM connection)
> less mp-log mgmtsrvr.log
> less mp-log devsrvr.log
> debug software show registered-services

# Interface status
> show interface all
> show routing route

# Security policy push status
> show running-config

# Force cert retrieval (if stuck)
> request certificate device retrieve
```

### Force re-bootstrap (when nothing else works)
```
> request shutdown system
# After reboot: bootstrap will run again from init-cfg
# Or: externally: gcloud compute instance-groups managed recreate-instances ...
```

---

## 10. Reset the firewall without losing SCM configuration

### Single firewall (from MIG)
```bash
# List firewalls in MIG
gcloud compute instance-groups managed list-instances \
  <PREFIX>-fw-autoscale-common \
  --region=$REGION --project=$PROJECT_ID

# Recreate (MIG will re-create from the current template)
gcloud compute instance-groups managed recreate-instances \
  <PREFIX>-fw-autoscale-common \
  --region=$REGION --project=$PROJECT_ID \
  --instances=<fw-instance-name>
```

### All firewalls (sequential, no downtime if ≥2)
```bash
INSTANCES=$(gcloud compute instance-groups managed list-instances \
  <PREFIX>-fw-autoscale-common \
  --region=$REGION --project=$PROJECT_ID \
  --format="value(name)")

for FW in $INSTANCES; do
  echo "Recreating $FW..."
  gcloud compute instance-groups managed recreate-instances \
    <PREFIX>-fw-autoscale-common \
    --region=$REGION --project=$PROJECT_ID \
    --instances=$FW
  # Wait until the new instance finishes bootstrap (~10-15 min)
  echo "Waiting for $FW bootstrap..."
  sleep 900  # 15 min
done
```

### Tag Collector VM (single-instance)
```bash
gcloud compute instances reset <PREFIX>-tc-vm-01 \
  --zone=<ZONE> --project=$PROJECT_ID
```

### After recreate: verification
```bash
# Wait ~15 min, then:
./scripts/diagnose-airs.sh
# Section 4: Firewalls – should have ✅ cert, ✅ SCM
```

---

---

## 11. Push Config OK but `is_first_push_done: False` + no config on the firewall

### Symptoms
- In SCM Workflows → NGFW Setup → Device Management firewall **Connected** ✅
- Device Certificate **Valid** ✅
- Push Config reports `Status: FIN, Result: OK` ✅
- BUT the LB backends are still **UNHEALTHY** ❌
- `show config running` on the firewall shows an **EMPTY config** (8 KB, no network/router/zones)
- `show advanced-routing route logical-router RT1` → `total route shown: 0`
- `show interface ethernet1/1`: `packets dropped: 386714, no route: 386714`

### Root cause
The standard "CommitAndPush" in SCM is **incremental** – it only sends delta
changes. After a firewall reset (or a fresh bootstrap) the network-level
configuration (interfaces, zones, router, NAT, security policy) is NOT
auto-pushed, even though it is set up in the SCM folder. A
**First Push** / **Initial Sync** is required which forces the full baseline.

### Diagnostics via SCM API

```bash
TOKEN=$(curl -s -d "grant_type=client_credentials&scope=tsg_id:$TSG_ID" \
    -u "$CLIENT_ID:$CLIENT_SECRET" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -X POST https://auth.apps.paloaltonetworks.com/oauth2/access_token | jq -r .access_token)

# Check flags
curl -s "https://api.strata.paloaltonetworks.com/config/setup/v1/devices" \
  -H "Authorization: Bearer $TOKEN" | jq '.data[] | {hostname, is_connected, is_first_push_done, license_match}'
```

**Symptoms in the response:**
```json
{ "is_connected": true, "is_first_push_done": false, "license_match": false }
```

`is_first_push_done: false` + `license_match: false` = confirmed initial push problem.

### Fix

**In the SCM UI:**
1. Manage → Configuration → Push Config
2. Select the folder with the firewalls (e.g. `gcp-airs`)
3. Targets: select all firewalls
4. **Tick the "Ignore Security Checks" checkbox** (if visible)
5. Push

**If that doesn't help:**
1. Workflows → NGFW Setup → Device Management → Cloud Managed Devices
2. Pick the device → action **Restart** (`request system restart`)
3. After restart the firewall will, on startup, fetch the full config from SCM

**If that still doesn't help:**
- Do a full teardown (section 13) and deploy from scratch
- The most common cause of a fundamental problem: stale URL/threat content
  database (section 12) or wrong template `tplname` mapping in bootstrap_options

### Workaround (manual)
You can also force the full configuration per element via the SCM API
(PUT zones, interfaces, router) BUT that will not change the
`is_first_push_done` flag.

---

## 12. Validation Error: 'remote-access' is not a valid reference (URL filtering)

### Symptoms
Push Config fails (`PUSHFAIL`) with an error in `details`:
```
Validation Error:
 profiles -> url-filtering -> Internet-Access-Default -> alert 'remote-access' is not a valid reference
 profiles -> url-filtering -> Internet-Access-Default -> alert is invalid
Commit failed
```

### Root cause
After a fresh bootstrap the firewall has an **EMPTY URL/threat content
database** (`app_version: 8902-9003` or older, instead of the current
`9093-10005+`). The predefined profile `Internet-Access-Default` (from the
default PAN-OS database) references a URL category `remote-access` which
does not exist in the old content database → commit validation fails.

### Check
```bash
# Via SCM API
curl -s "https://api.strata.paloaltonetworks.com/config/setup/v1/devices" \
  -H "Authorization: Bearer $TOKEN" | jq '.data[] | {hostname, app_version}'

# Via SSH on the firewall
ssh -i ~/.ssh/<key> admin@<mgmt-ip>
> show system info | match version
```

If `app_version` is `8902-xxxx` (or null) → **content out of date**.

### Fix (per firewall, ~5 min)

**SSH onto the firewall:**
```
> set cli pager off
> request content upgrade download latest
> show jobs id <jobid>     # wait for "Downld FIN OK"
> request content upgrade install version latest
> show jobs id <jobid>     # wait for "Content FIN OK" (up to 5 min)
```

After install, retry Push in SCM.

**Automation (script):**
```bash
for FW in $(gcloud compute instances list --filter="name~fw-autoscale" --format="value(name)"); do
  ZONE=$(gcloud compute instances list --filter="name=$FW" --format="value(zone.basename())")
  MGMT=$(gcloud compute instances describe $FW --zone=$ZONE \
    --format="value(networkInterfaces[1].accessConfigs[0].natIP)")
  echo -e "set cli pager off\nrequest content upgrade download latest\nexit" \
    | ssh -i ~/.ssh/<key> -o StrictHostKeyChecking=no admin@$MGMT
done
# Wait 3 min, then install:
for FW in $(...); do
  echo -e "request content upgrade install version latest\nexit" | ssh ...
done
```

### Prevention
After a fresh firewall bootstrap **ALWAYS** do a content update BEFORE the first Push Config:
```
> request content upgrade install-from-server
> request anti-virus upgrade install latest
> request url-filtering upgrade install latest
```

The PAN-OS image in the SCM template (`ai-runtime-security-byol-XXXXX`)
contains content from the moment the image was released – usually a few
weeks old.

---

## 13. Full environment teardown (clean restart)

### When to use it
- The environment is in an unstable state (mix of failed pushes, partial configurations)
- A "live" repair is taking too long
- Before a new from-scratch deployment (e.g. after major repo changes)

### Script
```bash
./scripts/teardown-all.sh \
  --scm-deployment /path/to/<template-name>_AIRS_GCP_us-central1_HASH \
  --scm-discovery  /path/to/panw-discovery-TSGID-onboarding/gcp \
  --yes
```

The script runs the sequence:
1. K8s namespaces delete (ai-chatbot, ai-api-chatbot)
2. Helm uninstall pan-cni
3. terraform destroy in SCM application_project (peering)
4. terraform destroy in SCM security_project (FW + LB + VPCs) – ~10-15 min
5. terraform destroy in SCM discovery onboarding (cloud account)
6. terraform destroy in our root TF (GKE + App VPC + IAM + bucket) – ~10-15 min
7. Cleanup residual Service Accounts

**Total time: ~25-30 min.**

### After teardown – DO MANUALLY (cannot be done via the API)

| # | Where | Action | Required? |
|---|---|---|---|
| 1 | **CSP UI** | Products → Software/Cloud NGFW Credits → Deployment Profile → **Deactivate firewalls** (release credits) | ✅ YES |
| 2 | SCM UI | AI Security → Cloud Account Manager → remove cloud account | ⚪ Optional (usually not possible via the UI – that's OK, the new onboarding TF will sort itself out) |
| 3 | SCM UI | Manage → Configuration → Folder Management → firewall config folder | ❌ **DO NOT DELETE** |

### ❌ Do not delete the firewall config folder (e.g. `gcp-airs`)

The folder contains **all the valuable configuration**:
- Security zones (untrust, trust, health-checks)
- Ethernet + loopback interfaces
- Logical Router (RT1) with static routes
- NAT policy + Security policy
- AI Security profiles, decryption rules
- Variables ($CL_POD, $CL_SVC, $eth1, $eth2)

**On the new deployment**:
1. In the SCM Add Protections wizard pick **the same folder** (`gcp-airs`) as the DG/SCM Folder
2. After `terraform apply security_project`: **check the LB IPs**:
   ```bash
   cd <new-template>/architecture/security_project && terraform output
   ```
3. **If the IPs changed** (usually the ILB stays at `10.1.2.253` with the same Trust VPC CIDRs):
   - SCM UI → Manage → Configuration → Variables → folder `gcp-airs`
   - Update `$ELB` (External LB IP) and `$ILB` (Internal LB IP)
   - Push Config
4. The rest of the configuration (zones/router/NAT/policy) **automatically applies to the new firewalls** registered in the folder.

### When done
Pull a fresh repo into a new location and start the deployment per DEPLOYMENT_GUIDE.

---

---

## 14. Pods in restart loop after namespace annotation + pan-cni install

### Symptoms
After running (PHASE 7):
```bash
helm install ai-runtime-security ai-runtime-security -n kube-system ...
kubectl annotate namespace ai-chatbot paloaltonetworks.com/firewall=pan-fw
kubectl rollout restart deployment/ai-chatbot -n ai-chatbot
```

The new pods get stuck:
- Status `Running 0/1`, `RESTARTS: N`, growing
- Events: `Liveness probe failed: ... context deadline exceeded`
- In SCM Logs Firewall/Traffic – NO traffic from 10.100.x.x

### Root cause #1 (MOST COMMON): missing Traffic Object in SCM

**Pan-cni hooks the pods correctly** (check `/host/appinfo/pan-cni.log` –
you can see "Creating VXLAN interface", "xdp_tunnel"). Packets flow to the
firewall via VXLAN UDP/6080. **The firewall receives the packets, tries to
decapsulate them, but there is no Traffic Object** mapping K8s Cluster ID → zone:

```bash
# On the firewall:
> show counter global | match drop
flow_policy_nofwd  <N>  drop  Session setup: no destination zone from forwarding
flow_host_decap_err <N>  drop  decapsulation error from control plane
```

**Fix:** see [DEPLOYMENT_GUIDE.md section 9.5](DEPLOYMENT_GUIDE.md#95--critical-traffic-object-in-scm-without-it-packets-are-dropped).

Create in SCM (folder gcp-airs):
1. Zone `k8s-cluster-1` (Layer3)
2. Traffic Object `k8s-cluster-1` (Type: K8s Cluster ID, ID: 1, Zone: `k8s-cluster-1`, Router: RT1)
3. Update security policy: add `k8s-cluster-1` to source zones
4. Push Config

After the push the pods will come back as Ready and traffic will be visible in SCM Logs.

### Root cause #2 (less common): TCP probes timeout despite Traffic Object

If the Traffic Object is configured but probes still time out:

```
kubelet (from node) → http://pod-ip:8080/health   (request via the standard path)
       ↓
pod application → HTTP 200 OK response             (pod wants to respond)
       ↓ pan-cni intercepts egress
       ↓ encapsulates → pan-ngfw-svc → ILB → firewall
firewall: receives the response packet without a matching session (asymmetric routing)
       ↓ packet drop
kubelet: timeout 5s → 3 failures → kill container → restart loop
```

Old pods (created BEFORE helm install pan-cni) work because they only use
the basic GKE CNI, without chaining.

### Fix (recommended, baked into the repo since commit e7dc4e5+)

In `kubernetes/app/deployment.yaml` use **TCP socket probes** instead of HTTP:

```yaml
# Instead of:
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  ...

# Use:
livenessProbe:
  tcpSocket:
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
```

**Why TCP works with pan-cni:**
- TCP socket probe = TCP SYN → SYN-ACK → ACK → RST/FIN (a short 4-packet session)
- No HTTP request/response cycle through the pan-cni tunnel
- Pan-cni treats short TCP probes differently from long HTTP traffic
- The Flask + gunicorn application listens on :8080 → SYN-ACK = OK

**Trade-off vs HTTP probe:**
- HTTP probe: detects an app crash even when the process is up
- TCP probe: only detects whether the port is listening (if the process is alive but the app crashed internally, the probe still passes)

For our setup (gunicorn + Flask, simple load) the TCP probe is sufficient.

### Verification after the fix
```bash
kubectl apply -f kubernetes/app/deployment.yaml
watch kubectl get pods -n ai-chatbot
# After ~1-2 min: new pods Ready 1/1, restart=0; old ones removed
```

Check in SCM Log Viewer → Firewall/Traffic → filter `Source Address contains 10.100`:
traffic with the real pod IPs (10.100.x.x) = **CNI chaining works, ai-chatbot is protected**.

### Alternative solutions (NOT recommended)
- **A**: Modify firewall security policy + MTU – requires deep tunnel debug, uncertain
- **C**: Per-pod annotation `paloaltonetworks.com/subnetfirewall=ns-secure/bypassfirewall` – bypass for the local subnet, requires subnet group config (not out-of-the-box on GKE)

---

## 15. Pods in CrashLoop after pan-cni install: SCM helm chart broken on GKE Dataplane V2

### Symptom
The helm chart from the SCM-generated TF ZIP (cn-series-airs-helm) is
installed. The pan-cni daemonset is `1/1 Running` on every node. The
`ai-chatbot` pods after `kubectl rollout restart`:

```
NAME                          READY   STATUS             RESTARTS
ai-chatbot-XXX                0/1     CrashLoopBackOff   N
```

Events: `Liveness probe failed: dial tcp 10.100.x.x:8080: i/o timeout`. The
pan-cni hook log (`/host/appinfo/pan-cni.log`) shows CORRECT configuration
– `Creating VXLAN interface`, `xdp_tunnel`, `Done with app pod securing`.
From the pod `ping 10.1.2.x` = 100% packet loss.

### Root cause

**The SCM helm chart creates an EndpointSlice with `conditions: {}` (empty).**
Cilium on GKE Dataplane V2 treats an endpoint without `ready: true` as
NOT-routable → packets from VXLAN to the ClusterIP `pan-ngfw-svc` are
dropped before reaching the ILB. The whole CNI chaining flow dies here.
The community helm chart (`r-airs-cni/airs-cni`) creates an EndpointSlice
without that field — Cilium defaults missing `conditions` to `ready=true`.

```yaml
# SCM chart (does NOT work):
endpoints:
- addresses: [10.1.2.253]
  conditions: {}    # ← empty, Cilium drop

# community helm chart (works):
endpoints:
  - addresses: [10.1.2.253]
  # conditions field ABSENT = default ready=true
```

### Fix: switch to the community helm chart

```bash
# 1. Remove SCM chart
helm uninstall ai-runtime-security -n kube-system

# 2. Add community helm repo + install
helm repo add r-airs-cni https://rweglarz.github.io/c-airs-helm/
helm repo update

# Find the firewall ILB IP:
TRUST_ILB=$(gcloud compute forwarding-rules list --project=$PROJECT_ID \
  --filter="region:us-central1 AND IPProtocol=UDP" \
  --format="value(IPAddress)" | head -1)
echo "Trust ILB: $TRUST_ILB"

# Install
helm install airs r-airs-cni/airs-cni -n kube-system \
  --set deployTo=gke \
  --set "endpoints[0].ip"=$TRUST_ILB \
  --set "fwtrustcidr=10.1.2.0/24"

# 3. Restart application
kubectl rollout restart deployment/ai-chatbot -n ai-chatbot
```

### Quick patch (fallback if you MUST use the SCM chart)

```bash
kubectl patch endpointslice pan-ngfw-svc-endpoints -n kube-system --type=json \
  -p='[{"op":"replace","path":"/endpoints/0/conditions","value":{"ready":true,"serving":true,"terminating":false}}]'
```

⚠️ The patch is LIVE – `helm upgrade` of the SCM chart will overwrite it. You need to reapply after every upgrade.

---

## 16. Pod→firewall trust 100% packet loss (FW rule blocks pod CIDR)

### Symptom
`ai-chatbot` pods are Ready BUT nothing leaves the pod:

```bash
kubectl exec -n ai-chatbot debug-pod -- ping 10.1.2.2   # 100% loss
kubectl exec -n ai-chatbot debug-pod -- curl http://10.1.2.2  # timeout
kubectl exec -n ai-chatbot debug-pod -- curl https://google.com  # timeout
```

BUT a `hostNetwork: true` pod (src = node IP) WORKS:

```bash
kubectl run test --image=busybox --overrides='{"spec":{"hostNetwork":true}}' \
  -it --rm -- ping 10.1.2.2   # OK, 0% loss
```

### Root cause
The SCM-generated TF creates `<prefix>-allow-trust-vpc-ingress` with source_ranges:
```
10.0.2.0/24, 172.16.0.0/28, 130.211.0.0/22, 35.191.0.0/16, 192.168.0.0/16
```

**Missing Pod CIDR (10.100.0.0/16) and Service CIDR (10.200.0.0/20).** The
Trust VPC firewall rule drops every packet with a pod IP. Direct
pod→firewall trust nic2 traffic does NOT work, and VXLAN-encapsulated
traffic doesn't either (outer src = pod IP).

### Fix
```bash
./scripts/fix-fw-trust-sources.sh
# Or manually:
gcloud compute firewall-rules update <prefix>-allow-trust-vpc-ingress \
  --source-ranges=10.0.2.0/24,10.100.0.0/16,10.200.0.0/20,172.16.0.0/28,130.211.0.0/22,35.191.0.0/16,192.168.0.0/16 \
  --project=$PROJECT_ID
```

After the update: pods in CrashLoop come up Ready in <30s.

⚠️ The fix is LIVE – `terraform apply` on security_project will overwrite it. Reapply after every apply.

---

## 17. External ELB → firewall → NodePort timeout (app VPC FW blocks trust subnet)

### Symptom
NAT and Security policy in SCM are configured correctly (DNAT untrust →
10.0.2.X:NodePort, source NAT to trust nic2). The SCM logs show a matched
session/NAT. But `curl http://<UNTRUST_ELB_IP>/` from the internet
**times out**.

The "client in the cluster" test (same NodePort, src=pod IP) WORKS:
```bash
kubectl exec -n ai-chatbot debug-pod -- curl http://10.0.2.6:32639/health   # HTTP 200
```

### Root cause
After DNAT the firewall does source NAT on trust nic2 (e.g. 10.1.2.2). The
packet flies `src=10.1.2.2 → dst=10.0.2.6:32639` through the trust→app
VPC peering. On the app VPC the rule `airs-app-allow-internal` by default
allows:
```
10.0.2.0/24, 10.100.0.0/16, 10.200.0.0/20
```

**Missing `10.1.2.0/24`** (the firewall's trust subnet). The GCP-level FW drops the packet BEFORE it reaches the node.

### Fix
```bash
./scripts/fix-fw-trust-sources.sh
# (section 2 of the script handles this – it patches both sides in one pass)
```

In the repo `modules/vpc/variables.tf` already has the variable
`trust_subnet_cidr` (default `10.1.2.0/24`), so `terraform apply` will
natively set this for new deployments. The script is for environments
already deployed without re-apply.

---

## 18. External LB (untrust ELB) timeout from internet, only health-checks visible in SCM Logs

### Symptom
Everything is configured (NAT inbound, security policy, address objects,
push OK on the firewalls). `curl http://<UNTRUST_ELB_IP>/health` from the
laptop **times out** (HTTP=000). In **SCM Logs → Traffic** you can only
see sessions from Google ELB health-check ranges (35.191.0.0/16,
130.211.0.0/22 etc.), no sessions from your user.

### Root cause
The SCM-generated TF creates `<prefix>-allow-untrust-vpc-ingress` with source_ranges:
```
35.191.0.0/16, 130.211.0.0/22, 209.85.152.0/22, 209.85.204.0/22
```

These are **ONLY Google ELB health-check ranges**. User traffic
(`0.0.0.0/0` or your public IP) is **NOT permitted at the GCP VPC level**.
The packet is dropped BEFORE it reaches the firewall – hence no traffic
in SCM Logs.

### Fix
```bash
./scripts/fix-untrust-web-ingress.sh
# Default: source 0.0.0.0/0 (the entire internet, for the webinar)

# Or restrict to a specific IP:
ALLOWED_SOURCES="<YOUR_PUBLIC_IP>/32" ./scripts/fix-untrust-web-ingress.sh
```

The script creates the rule `<prefix>-allow-untrust-web-from-internet`
(TCP/80,443) on the untrust VPC. You control per-source/policy/threat
granularity in the **firewall security policy in SCM** – this GCP rule is
just the gateway.

> 💡 **Why did HTTPS (443) respond with 404 even though 80 was blocked?**
> The firewall web GUI listens on :443 (mgmt console). 209.85.0.0/16 was permitted
> in the default rule, but your public IP was not. After adding `0.0.0.0/0` on 80/443
> both paths (DNAT → app on :80, web GUI on :443) work for all sources.

---

## Reference links

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) – full deployment guide
- [SCM_CONFIGURATION_REQUIRED.md](SCM_CONFIGURATION_REQUIRED.md) – post-deployment SCM configuration
- [ARCHITECTURE_DIAGRAMS.md](ARCHITECTURE_DIAGRAMS.md) – diagrams
- PAN docs: https://docs.paloaltonetworks.com/ai-runtime-security
- SCM docs: https://docs.paloaltonetworks.com/strata-cloud-manager
- SCM API: https://pan.dev/scm/docs/home/
- CSP: https://support.paloaltonetworks.com (Device Certificates, Deployment Profiles)
- SCM: https://stratacloudmanager.paloaltonetworks.com

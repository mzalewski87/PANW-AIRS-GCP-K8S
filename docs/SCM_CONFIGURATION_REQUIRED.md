# Required configuration in Strata Cloud Manager (SCM)

> **Perform the steps below BEFORE installing the Helm chart (PHASE 7).**
>
> Without this configuration CNI chaining will not work — the firewall will not
> see the real pod IPs (10.100.x.x) and will not be able to route traffic from
> pods or NAT it on egress.

---

## 1. Static Routes for Pod/Service CIDR

**SCM → Configuration → NGFW and Prisma Access → Device Settings → Routing → Logical Routers**

Edit the existing Logical Router (e.g. `airs-lr`) and add two static routes:

| Destination | Next Hop Interface | Gateway | Purpose |
|---|---|---|---|
| `10.100.0.0/16` (GKE Pod CIDR) | `ethernet1/2` (trust) | Gateway from DHCP eth1/2 | Return traffic to pods |
| `10.200.0.0/20` (GKE Service CIDR) | `ethernet1/2` (trust) | Gateway from DHCP eth1/2 | Traffic to K8s services |

> 💡 You will find the gateway IP in: Device Management → [firewall] → Interfaces → eth1/2 → DHCP Runtime Info.
>
> The route `10.0.0.0/8` (if it exists from section 8.5) covers both CIDRs.
> If you have it — additional routes are NOT needed.
> Check: if you have the 10.0.0.0/8 route → skip this step.

---

## 2. Source NAT Policy for traffic from pods

**SCM → Configuration → Network Policies → NAT → Add Rule**

Add a NAT rule ABOVE the existing `outbound` rule:

| Parameter | Value |
|---|---|
| Rule Name | `pods-outbound` |
| Position | Pre-Rule (ABOVE `outbound`) |
| **Original Packet** | |
| Source Zone | `trust` |
| Source Address | `10.100.0.0/16`, `10.200.0.0/20` |
| Destination Zone | `untrust` |
| **Translated Packet** | |
| Source Translation | Dynamic IP and Port (DIPP) |
| Interface | `ethernet1/1` (untrust) |

> 💡 If the existing `outbound` rule (from section 8.6) has Source Address = `any`,
> it also covers traffic from pods. In that case the additional NAT rule is NOT needed.
> Check your `outbound` rule — if Source = `any` → skip this step.

---

## 3. Security Policy for traffic from pods

**SCM → Configuration → Security Services → Security Policy**

If you have an `allow-all` rule with Source = `any` → traffic from pods is already allowed.

If you have granular rules — add:

| Parameter | Value |
|---|---|
| Name | `allow-pods-outbound` |
| Source Zone | `trust` |
| Source Address | `10.100.0.0/16` |
| Destination Zone | `untrust` |
| Action | Allow |
| Security Profile | (optional) AI Security Profile |

---

## 4. Trust VPC Firewall Rules (GCP)

Traffic from pods (10.100.x.x) must be able to reach the firewall through the Trust VPC.
Check the GCP Firewall Rules on the Trust VPC:

```bash
gcloud compute firewall-rules list --project=$PROJECT_ID \
  --filter="network ~ trust" --format="table(name,direction,sourceRanges,allowed)"
```

If the `allow-trust-ingress` rule does not contain `10.100.0.0/16` — add it:

Open `architecture/security_project/terraform.tfvars` from the downloaded SCM ZIP.
Find the `firewall_rules` / `allow-trust-ingress` section and add the Pod/Service CIDR:

```hcl
source_ranges = [
  "35.191.0.0/16",    # GCP health checks
  "130.211.0.0/22",   # GCP health checks
  "10.0.2.0/24",      # App subnet (GKE nodes)
  "10.100.0.0/16",    # GKE Pod CIDR  ← ADD
  "10.200.0.0/20"     # GKE Service CIDR  ← ADD
]
```

Then: `terraform apply` in the `architecture/security_project/` directory.

Alternatively — manually via gcloud:
```bash
# Find the rule name:
gcloud compute firewall-rules list --project=$PROJECT_ID \
  --filter="network ~ trust AND direction=INGRESS" --format="value(name)"

# Add source ranges:
gcloud compute firewall-rules update <RULE_NAME> \
  --project=$PROJECT_ID \
  --source-ranges="35.191.0.0/16,130.211.0.0/22,10.0.2.0/24,10.100.0.0/16,10.200.0.0/20"
```

---

## 5. Push Config

**SCM → Manage → Configuration → Push Config** → select the folder with the firewall → **Push**

---

## Verification

After configuration and pod restart:

```bash
# 1. Restart ai-chatbot pods
kubectl rollout restart deployment/ai-chatbot -n ai-chatbot

# 2. Send a request to the chatbot

# 3. Check firewall logs in SCM:
#    Log Viewer → Network/Firewall Traffic
#    Filter: Source Address contains 10.100
#    You should see traffic from 10.100.x.x (ai-chatbot pod IPs)

# 4. On the firewall CLI (if you have SSH):
#    > show session all filter source 10.100.0.0/16
```

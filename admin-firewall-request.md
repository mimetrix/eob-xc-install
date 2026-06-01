# AWS SG change request — F5 XC tenant admin

**Site:** `srikan-tf-test-0` (tenant `platform-svc-nbryikfr`, staging)
**Requester:** e.starin@f5.com
**Purpose:** Expose the Mantis EoB Tawon Dashboard so users can reach it from a browser
without an SSH tunnel.

## Background

The EoB Tawon Dashboard runs on **master-0** (host IP `172.31.44.247`, public
`3.147.217.91`) using `hostNetwork: true`. The dashboard `sengat` process listens on
`*:8789` on master-0, confirmed via:

```
$ sudo ss -tlnp | grep 8789
LISTEN 0 16384 *:8789 *:* users:(("sengat",pid=2956012,fd=3))
```

The on-node `vpm-segment-inbound` iptables rules **do not** apply to this traffic —
they're scoped to `-i vhost-seg+` (Vega's tenant overlay) and the node IP lives on
`vhost0`. The only barrier between a browser on the open internet and `sengat` is
the AWS security group attached to the master EC2 instances.

## Required change — AWS security group

Please add the following inbound rules to the AWS SG attached to the master EC2
instances on this site (master-0 is `i-0d56d3f771f40f639`, primary SG
`sg-0aaa9b760f0bf438b`).

| Port | Proto | Purpose | Required |
|------|-------|---------|----------|
| 8789 | TCP   | Tawon Dashboard (sengat UI) | **yes** |
| 18443 | TCP  | Operator Prometheus metrics (kube-rbac-proxy) | optional |
| 8222 | TCP   | NATS monitoring page | optional |

Source: whatever your tenant access policy dictates — a corporate CIDR or
`0.0.0.0/0` depending on your hardening posture.

## Verification

From a workstation that can reach the public IP of master-0:

```
curl -v http://3.147.217.91:8789/
```

Expected: `HTTP/1.1 200 OK` and the Tawon Dashboard HTML.

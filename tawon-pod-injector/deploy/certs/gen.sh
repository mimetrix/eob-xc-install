#!/bin/bash
# Generates a self-signed TLS keypair for the tawon-pod-injector webhook.
# Outputs PEM-encoded cert/key to stdout-friendly variables that the
# deploy manifest can consume via base64 in a Secret + caBundle.
#
# The CN/SAN must match the webhook Service DNS:
#   tawon-pod-injector.tawon-operator.svc
#
# Apiserver dials the webhook via that name and verifies the cert
# against the caBundle field in the MutatingWebhookConfiguration.
#
# Usage:
#   ./gen.sh > certs.env
#   source certs.env
#   envsubst < ../k8s/manifest.template.yaml > ../k8s/manifest.yaml
#
# Or just call this and pipe the output into a YAML envsubst.

set -euo pipefail

NAMESPACE="${NAMESPACE:-tawon-operator}"
SVC="${SVC:-tawon-pod-injector}"
DAYS="${DAYS:-3650}"   # 10y — fine for a dev XC site

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Self-signed cert acts as its own CA. The webhook server uses
# tls.crt/tls.key; the apiserver trusts caBundle = same cert.
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TMP/tls.key" \
    -out    "$TMP/tls.crt" \
    -days   "$DAYS" \
    -subj   "/CN=${SVC}.${NAMESPACE}.svc" \
    -addext "subjectAltName=DNS:${SVC},DNS:${SVC}.${NAMESPACE},DNS:${SVC}.${NAMESPACE}.svc,DNS:${SVC}.${NAMESPACE}.svc.cluster.local" \
    2>/dev/null

# Emit base64 (single-line, no wrapping) for both PEM blocks.
echo "TLS_CRT=\"$(base64 -w0 < "$TMP/tls.crt")\""
echo "TLS_KEY=\"$(base64 -w0 < "$TMP/tls.key")\""
echo "CA_BUNDLE=\"$(base64 -w0 < "$TMP/tls.crt")\""   # cert is its own CA

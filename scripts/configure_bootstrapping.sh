#!/usr/bin/env bash

setup_environment () {
  set -x
  VAULT_IP="192.168.2.11"

  IFACE=`route -n | awk '$1 == "192.168.2.0" {print $8;exit}'`
  CIDR=`ip addr show ${IFACE} | awk '$2 ~ "192.168.2" {print $2}'`
  IP=${CIDR%%/24}

}

configure_k8s_vault_bootstrapping () {
  # provisioner policy hcl definition file
  tee provisioner_policy.hcl <<EOF
  # Manage auth backends broadly across Vault
  path "auth/*"
  {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
  }

  # List, create, update, and delete auth backends
  path "sys/auth/*"
  {
    capabilities = ["create", "read", "update", "delete", "sudo"]
  }

  # List existing policies
  path "sys/policy"
  {
    capabilities = ["read"]
  }

  # Create and manage ACL policies
  path "sys/policy/*"
  {
    capabilities = ["create", "read", "update", "delete", "list"]
  }

  # List, create, update, and delete key/value secrets
  path "secret/*"
  {
    capabilities = ["create", "read", "update", "delete", "list"]
  }

  # List, create, update, and delete key/value secrets
  path "kv/*"
  {
    capabilities = ["create", "read", "update", "delete", "list"]
  }
EOF
  VAULT_TOKEN=`cat .vault-token`
  # create provisioner policy
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault policy write provisioner provisioner_policy.hcl

  # create a provisioner token
  PROVISIONER_TOKEN=`VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault token create -policy=provisioner -field=token`
  echo -n ${PROVISIONER_TOKEN} > .provisioner-token
  chmod ugo+r .provisioner-token

  # Configure Vault Account on Kubernetes
  kubectl --kubeconfig kubeconfig create serviceaccount vault-auth
  # Configre Vault Account Policy
  kubectl --kubeconfig kubeconfig create -f conf/k8s/vault_k8s_policy.yaml

  # Enable kubernetes backend in vault
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault auth enable kubernetes

  # enable k8s vault demo role
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault write auth/kubernetes/role/demo \
        bound_service_account_names=vault-auth \
        bound_service_account_namespaces=default \
        policies=provisioner \
        ttl=1h

  # Get the kubernetes secret associated with this account
  service_secret=`kubectl --kubeconfig kubeconfig get serviceaccount vault-auth -o json | jq -Mr '.secrets[].name'`

  # Then use the secret to get the Service JWT
  service_jwt=`kubectl --kubeconfig kubeconfig get secrets ${service_secret} -o json | jq -Mr '.data.token' | base64 --decode`

  # We also need to locate the CA certificate used by K8S
  kubectl --kubeconfig kubeconfig get secrets ${service_secret} -o json | jq -Mr '.data["ca.crt"]' | base64 --decode > k8sca.crt

  # Enable kubernetes backend in vault
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200"  vault write auth/kubernetes/config \
    token_reviewer_jwt="${service_jwt}" \
    kubernetes_host=https://192.168.2.9:6443 \
    kubernetes_ca_cert=@k8sca.crt
  
  # Review Services
  kubectl --kubeconfig kubeconfig get all --all-namespaces

}

setup_environment
configure_k8s_vault_bootstrapping

# HashiCorp Vault integration with Kubernetes

This repository provides a self-contained Vagrantfile that can be used to walk-through the steps required to integrate Vault and Kubernetes. The Kubernetes native apis are used to facilitate bootstrapping containers in Pods with HashiCorp Vault Secrets.

__Prerequisites__
 - [Vagrant](https://www.vagrantup.com/docs/installation/)
 - [Virtualbox](https://www.virtualbox.org/wiki/Downloads)
 - [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

__Step 0__ - Install Vault with a Consul Backend _[Installation out of scope of this example]_

__Step 1__ - Install Kubernetes _[Installation out of scope of this example]_

- Simply follow the instructions below to install vault and kubernetes:

``` bash
git clone git@github.com:allthingsclowd/vault_kubernetes_integration.git
cd vault_kubernetes_integration
vagrant up
```

__Step 2__ - Configure a Kubernetes Service Account

- Install Vault service account on Kubernetes
``` bash
kubectl --kubeconfig kubeconfig create serviceaccount vault-auth
```

- Give this account permission to tokenreview at cluster level
``` bash
kubectl --kubeconfig kubeconfig create -f - -o yaml << EOF
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: default
EOF
```

- Locate the Service JWT token for this account. First grab the secret token
``` bash
service_secret=`kubectl --kubeconfig kubeconfig get serviceaccount vault-auth -o json | jq -Mr '.secrets[].name'`
```

- Then use the secret to get the Service JWT
``` bash
service_jwt=`kubectl --kubeconfig kubeconfig get secrets ${service_secret} -o json | jq -Mr '.data.token' | base64 -D`
```

- We also need to locate the CA certificate used by K8S
``` bash
kubectl --kubeconfig kubeconfig get secrets ${service_secret} -o json | jq -Mr '.data["ca.crt"]' | base64 -D > k8sca.crt
```

__Step 3__ - Configure Vault

- Enable the kubernetes auth method
``` bash
export VAULT_TOKEN=$(cat .vault-token)
export VAULT_ADDR='http://192.168.2.11:8200'
vault auth enable kubernetes
```

- Configure vault to talk to kubernetes
``` bash
export VAULT_TOKEN=$(cat .vault-token)
export VAULT_ADDR='http://192.168.2.11:8200'
vault write auth/kubernetes/config \
    token_reviewer_jwt="${service_jwt}" \
    kubernetes_host=https://192.168.2.9:6443 \
    kubernetes_ca_cert=@k8sca.crt

```
- Create a provisioner policy (this was created during the Vault installation process - see install_vault.sh)
``` bash
create_provisioner_policy () {
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
  VAULT_TOKEN=`cat /usr/local/bootstrap/.vault-token`
  # create provisioner policy
  sudo VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${IP}:8200" vault policy write provisioner provisioner_policy.hcl

}
```
- Create a named role (demo)
``` bash
vault write auth/kubernetes/role/demo \
    bound_service_account_names=vault-auth \
    bound_service_account_namespaces=default \
    policies=provisioner \
    ttl=1h
```

__Step 4__ - Verification - Get a Vault Token

- CLi - get a vault token
``` bash
vault write auth/kubernetes/login role=demo jwt=${service_jwt}
```

Output
``` bash
Key                                       Value
---                                       -----
token                                     s.2H0WKxNLJmYyogOc1VvHN7GP
token_accessor                            2mjOKEcEEQf7L2AXqkkyoUGw
token_duration                            1h
token_renewable                           true
token_policies                            ["default"]
identity_policies                         []
policies                                  ["default"]
token_meta_service_account_name           vault-auth
token_meta_service_account_namespace      default
token_meta_service_account_secret_name    vault-auth-token-95dcm
token_meta_service_account_uid            e879db7b-e0db-11e8-b746-0800275f82b1
token_meta_role
```

- API
``` bash
curl \
    --request POST \
    --data "{\"jwt\": \"${service_jwt}\", \"role\": \"demo\"}" \
    http://192.168.2.11:8200/v1/auth/kubernetes/login | jq  -r .auth.client_token
```

Output
```
s.2MB8zvVjrQ7mbijfzgTSA2Or
```

- Now let's check that it's a valid token by logging in with it
``` bash 
# Stop using the previously set token 
unset VAULT_TOKEN
vault login token=$(curl \
    --request POST \
    --data "{\"jwt\": \"${service_jwt}\", \"role\": \"demo\"}" \
    http://192.168.2.11:8200/v1/auth/kubernetes/login | jq  -r .auth.client_token)
```

Output
``` bash
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                                       Value
---                                       -----
token                                     s.5a8LG09xOJwRAA75APQvwbG8
token_accessor                            LJRBEnzDN3NpCMaXVQUGQZMh
token_duration                            59m59s
token_renewable                           true
token_policies                            ["default"]
identity_policies                         []
policies                                  ["default"]
token_meta_role                           demo
token_meta_service_account_name           vault-auth
token_meta_service_account_namespace      default
token_meta_service_account_secret_name    vault-auth-token-95dcm
token_meta_service_account_uid            e879db7b-e0db-11e8-b746-0800275f82b1
```

__Step 5__ - Manually verify access from within a Kubernetes PoD

- Start a pod
``` bash
kubectl --kubeconfig kubeconfig run vault-demo --rm -i --tty --serviceaccount=vault-auth --image alpine
```

- _Now to verify from inside a kubernetes container within a pod_
``` bash
# Update the image & install prerequisites
apk update
apk add curl jq

# Get the container token
KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Authenticate against Vault backend and get a Vault token
VAULT_K8S_TOKEN=$(curl --request POST --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "demo"}' http://192.168.2.11:8200/v1/auth/kubernetes/login | jq -r .auth.client_token)

# Login to Vault with the new token
curl \
    --header "X-Vault-Token: ${VAULT_K8S_TOKEN}" \
    http://192.168.2.11:8200/v1/auth/token/lookup-self | jq .
```

Successful Output
``` bash
{
  "request_id": "87a5754a-505d-9d24-bccb-ea1cb7a02b00",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": {
    "accessor": "2N4OirI1uoxdKatTbHhpJaoV",
    "creation_time": 1541433505,
    "creation_ttl": 3600,
    "display_name": "kubernetes-default-vault-auth",
    "entity_id": "67f0fd81-ccd0-ebe1-2ba9-809c9d2e7bd9",
    "expire_time": "2018-11-05T16:58:25.683029832Z",
    "explicit_max_ttl": 0,
    "id": "s.1LP2bcQUaOYWnsuUHHWbFm60",
    "issue_time": "2018-11-05T15:58:25.683029534Z",
    "meta": {
      "role": "demo",
      "service_account_name": "vault-auth",
      "service_account_namespace": "default",
      "service_account_secret_name": "vault-auth-token-95dcm",
      "service_account_uid": "e879db7b-e0db-11e8-b746-0800275f82b1"
    },
    "num_uses": 0,
    "orphan": true,
    "path": "auth/kubernetes/login",
    "policies": [
      "default"
    ],
    "renewable": true,
    "ttl": 3372,
    "type": "service"
  },
  "wrap_info": null,
  "warnings": null,
  "auth": null
}
```

__Step 6__ - [Example container bootstrapped go application](https://github.com/allthingsclowd/VaultServiceIDFactory)

- Review the docker file
``` dockerfile
FROM alpine
RUN apk add --update \
    curl bash jq \
    && rm -rf /var/cache/apk/*
ADD /VaultServiceIDFactory /VaultServiceIDFactory
ADD scripts/docker_init.sh /docker_init.sh
CMD [/docker_init.sh]
```

- Review the container init script
``` bash
#!/bin/bash

# Start the first process
./VaultServiceIDFactory -vault="http://192.168.2.11:8200"&
status=$?
if [ ${status} -ne 0 ]; then
  echo "Failed to start VaultServiceIDFactory: ${status}"
  exit ${status}
fi

if [ -f /usr/local/bootstrap/.provisioner-token ]; then
  echo "Running Docker locally with access to vagrant instance filesystem"
  VAULT_TOKEN=`cat /usr/local/bootstrap/.provisioner-token`
else
  echo "Looking for secret keys on Kubernetes"
  # Get the container token
  KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  # Authenticate against Vault backend and get a Vault token
  VAULT_TOKEN=$(curl --request POST \
                          --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "demo"}' \
                          http://192.168.2.11:8200/v1/auth/kubernetes/login | jq -r .auth.client_token)
fi

WRAPPED_PROVISIONER_TOKEN=$(curl --request POST \
                                  --data '{
                                            "policies": [
                                              "provisioner"
                                              ],
                                            "metadata": {
                                              "user": "Grahams Demo"
                                              },
                                            "ttl": "1h",
                                            "renewable": true
                                          }' \
                                  --header "X-Vault-Token: ${VAULT_TOKEN}" \
                                  --header "X-Vault-Wrap-TTL: 60" \
                              http://192.168.2.11:8200/v1/auth/token/create | jq -r .wrap_info.token)


curl -s --header "Content-Type: application/json" \
        --request POST \
        --data "{\"token\":\"${WRAPPED_PROVISIONER_TOKEN}\"}" \
        http://127.0.0.1:8314/initialiseme

curl -s http://127.0.0.1:8314/health 

# Naive check runs checks once a minute to see if either of the processes exited.
# This illustrates part of the heavy lifting you need to do if you want to run
# more than one service in a container. The container exits with an error
# if it detects that either of the processes has exited.
# Otherwise it loops forever, waking up every 60 seconds

while sleep 60; do
  ps aux |grep VaultServiceIDFactory |grep -q -v grep
  PROCESS_1_STATUS=$?
  # If the greps above find anything, they exit with 0 status
  # If they are not both 0, then something is wrong
  if [ ${PROCESS_1_STATUS} -ne 0 ]; then
    echo "VaultServiceIDFactory has already exited."
    exit 1
  fi
done
```
- Test the aplication
``` bash
kubectl --kubeconfig kubeconfig run vault-demo --rm -i --tty --serviceaccount=vault-auth --image allthingscloud/vaultsecretidfactory
```

Successful Output
``` bash
kubectl run --generator=deployment/apps.v1beta1 is DEPRECATED and will be removed in a future version. Use kubectl create instead.
If you don\'t see a command prompt, try pressing enter.
100  1532  100   651  100   881    612    829  0:00:01  0:00:01 --:--:--  1443
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   844  100   337  100   507  12481  18777 --:--:-- --:--:-- --:--:-- 32461

Debug Vars Start

VAULT_ADDR:> http://192.168.2.11:8200

URL:> /v1/sys/wrapping/unwrap

TOKEN:> s.4hGWun5lMWMZQ5spT6TcJu44

DATA:> map[]

VERB:> POST

Debug Vars End
response Status: 200 OK
response Headers: map[Cache-Control:[no-store] Content-Type:[application/json] Date:[Tue, 06 Nov 2018 21:34:18 GMT] Content-Length:[449]]


response result:  map[data:<nil> wrap_info:<nil> warnings:<nil> auth:map[policies:[default provisioner] metadata:<nil> lease_duration:3600 renewable:true token_type:serviceclient_token:s.3kOHQuFE9S235xnVzY1Cj8c8 accessor:5X6BOfpnOldute8MRKMuS7Sp token_policies:[default provisioner] entity_id:03d315eb-e259-3f49-6034-27faaf820d3b] request_id:c1895108-90ec-ff82-6ddb-7a3b503b2d04 lease_id: renewable:false lease_duration:0]
2018/11/06 21:34:17 s.3kOHQuFE9S235xnVzY1Cj8c8
Wrapped Token Received: s.4hGWun5lMWMZQ5spT6TcJu44
UnWrapped Vault Provisioner Role Token Received: s.3kOHQuFE9S235xnVzY1Cj8c8
2018/11/06 21:34:17 INITIALISED
INITIALISED
```
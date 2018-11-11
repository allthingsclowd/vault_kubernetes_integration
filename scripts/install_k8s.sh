#!/usr/bin/env bash

setup_environment () {
  set -x
  VAULT_IP="192.168.2.11"

  IFACE=`route -n | awk '$1 == "192.168.2.0" {print $8;exit}'`
  CIDR=`ip addr show ${IFACE} | awk '$2 ~ "192.168.2" {print $2}'`
  IP=${CIDR%%/24}

}

install_specific_docker_version () {
    
    sudo apt-get install -y software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    sudo apt-get update

    sudo apt-cache policy docker-ce
    sudo apt-get install -y docker-ce="17.03.3~ce-0~ubuntu-xenial"
}

install_kubernetes () {
    
    install_specific_docker_version
    apt-get update && apt-get install -y apt-transport-https
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
    deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    # kubelet requires swap off
    swapoff -a
    # keep swap off after reboot
    sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    # conifgure startup 
    sed -i '0,/ExecStart=/s//Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=cgroupfs"\n&/' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    echo This VM has IP address ${IP}
    # Set up Kubernetes
    NODENAME=$(hostname -s)
    kubeadm init --apiserver-cert-extra-sans=${IP}  --node-name ${NODENAME}
    # Set up admin creds for the vagrant user
    echo "Copying credentials to /home/vagrant"
    if [ -f /vagrant/kubeconfig ]; then
        rm -rf /vagrant/kubeconfig
    fi
    sudo --user=vagrant mkdir -p /home/vagrant/.kube
    cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
    chown $(id -u vagrant):$(id -g vagrant) /home/vagrant/.kube/config
    # Configure kube config file for use from the host
    cat /etc/kubernetes/admin.conf | sed  "s/server:\ .*/server: https:\/\/${IP}:6443/" > /vagrant/kubeconfig
    # Allow pods to run on the master node
    kubectl --kubeconfig /home/vagrant/.kube/config taint nodes --all node-role.kubernetes.io/master-
    # Deploy an overlay network
    kubectl --kubeconfig /home/vagrant/.kube/config apply -f https://cloud.weave.works/k8s/net?k8s-version=$(kubectl --kubeconfig /home/vagrant/.kube/config version | base64 | tr -d '\n')
    # Deploy NGINX for use as the Ingress Controller
    kubectl --kubeconfig /home/vagrant/.kube/config apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml
    kubectl --kubeconfig /home/vagrant/.kube/config apply -f /vagrant/conf/k8s/nginx-ingress.yaml
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
  VAULT_TOKEN=`cat /vagrant/.vault-token`
  # create provisioner policy
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault policy write provisioner provisioner_policy.hcl

  # create a provisioner token
  PROVISIONER_TOKEN=`VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault token create -policy=provisioner -field=token`
  echo -n ${PROVISIONER_TOKEN} > .provisioner-token
  chmod ugo+r .provisioner-token

  # Configure Vault Account on Kubernetes
  kubectl --kubeconfig /home/vagrant/.kube/config create serviceaccount vault-auth
  # Configre Vault Account Policy
  kubectl --kubeconfig /home/vagrant/.kube/config create -f /vagrant/conf/k8s/vault_k8s_policy.yaml

  # Enable kubernetes backend in vault
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault auth enable kubernetes

  # enable k8s vault demo role
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200" vault write auth/kubernetes/role/demo \
        bound_service_account_names=vault-auth \
        bound_service_account_namespaces=default \
        policies=provisioner \
        ttl=1h

  # Get the kubernetes secret associated with this account
  service_secret=`kubectl --kubeconfig /home/vagrant/.kube/config get serviceaccount vault-auth -o json | jq -Mr '.secrets[].name'`

  # Then use the secret to get the Service JWT
  service_jwt=`kubectl --kubeconfig /home/vagrant/.kube/config get secrets ${service_secret} -o json | jq -Mr '.data.token' | base64 --decode`

  # We also need to locate the CA certificate used by K8S
  kubectl --kubeconfig /home/vagrant/.kube/config get secrets ${service_secret} -o json | jq -Mr '.data["ca.crt"]' | base64 --decode > k8sca.crt

  # Enable kubernetes backend in vault
  VAULT_TOKEN=${VAULT_TOKEN} VAULT_ADDR="http://${VAULT_IP}:8200"  vault write auth/kubernetes/config \
    token_reviewer_jwt="${service_jwt}" \
    kubernetes_host=https://192.168.2.9:6443 \
    kubernetes_ca_cert=@k8sca.crt
  
  # Review Services
  kubectl --kubeconfig /home/vagrant/.kube/config get all --all-namespaces

}

deploy_demo_application () {

    # Configre application ingress rules
    kubectl --kubeconfig /home/vagrant/.kube/config create -f /vagrant/conf/k8s/vault-ingress.yaml
    # Deploy demo appliation
    kubectl --kubeconfig /home/vagrant/.kube/config apply -f /vagrant/conf/k8s/vaultsecretidfactory.yaml
    # Review Services
    kubectl --kubeconfig /home/vagrant/.kube/config get all --all-namespaces
    # Test the access
    curl -kL http://192.168.2.9/health
    # Output
    echo "============= Check the Cluster Components =============="
    echo "kubectl --kubeconfig kubeconfig get all --all-namespaces"
    echo "============= Check the Demo Application ================"
    echo "curl -kL https://192.168.2.9/health"
    echo "curl -kL https://192.168.2.9/initialiseme"
    echo "curl -kL https://192.168.2.9/approlename"
    echo "=====================The End============================="
}

setup_environment
install_specific_docker_version
install_kubernetes
configure_k8s_vault_bootstrapping
deploy_demo_application



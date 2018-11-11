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

setup_environment
install_specific_docker_version
install_kubernetes



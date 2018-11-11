#!/usr/bin/env bash

deploy_demo_application () {

    # Configre application ingress rules
    kubectl --kubeconfig kubeconfig create -f conf/k8s/vault-ingress.yaml
    # Deploy demo appliation
    kubectl --kubeconfig kubeconfig apply -f conf/k8s/vaultsecretidfactory.yaml
    # Review Services
    kubectl --kubeconfig kubeconfig get all --all-namespaces
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

deploy_demo_application
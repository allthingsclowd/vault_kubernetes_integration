# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|

  ENV['K8S_IP']||="192.168.2.9"
  ENV['K8S_NAME']||="k8s"
  ENV['VAULT_IP']||="192.168.2.11"
  ENV['VAULT_NAME']||="vault01"

  #global config
  config.vm.synced_folder ".", "/vagrant"
  config.vm.synced_folder ".", "/usr/local/bootstrap"

  config.vm.provider "virtualbox" do |v|
      v.memory = 8192
      v.cpus = 2
  end

  config.vm.define "k8s01" do |k8s01|
      k8s01.vm.hostname = ENV['K8S_NAME']
      k8s01.vm.box = "bento/ubuntu-16.04"
      k8s01.vm.network "private_network", ip: ENV['K8S_IP']
      k8s01.vm.provision "docker"
      k8s01.vm.provision "shell", path: "scripts/install_k8s.sh", run: "always"
  end

  config.vm.provider "virtualbox" do |v|
      v.memory = 1024
      v.cpus = 1
  end

  config.vm.define "vault01" do |vault01|
      vault01.vm.hostname = ENV['VAULT_NAME']
      vault01.vm.box = "allthingscloud/web-page-counter"
      vault01.vm.provision "shell", path: "scripts/install_consul.sh", run: "always"
      vault01.vm.provision "shell", path: "scripts/install_vault.sh", run: "always"
      vault01.vm.network "private_network", ip: ENV['VAULT_IP']
      vault01.vm.network "forwarded_port", guest: 8500, host: 8500
      vault01.vm.network "forwarded_port", guest: 8200, host: 8200
  end

end

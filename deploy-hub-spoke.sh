#!/bin/bash
# Azure Secure Hub-and-Spoke Deployment Script

RG="rg-hub-spoke-portfolio"
LOC="polandcentral"

echo "Creating Resource Group..."
az group create --name $RG --location $LOC

echo "Creating VNets & Subnets..."
az network vnet create --resource-group $RG --name vnet-hub --address-prefix 10.0.0.0/16 \
  --subnet-name nva-subnet --subnet-prefix 10.0.2.0/24

az network vnet subnet create --resource-group $RG --vnet-name vnet-hub \
  --name GatewaySubnet --address-prefix 10.0.1.0/24

az network vnet create --resource-group $RG --name vnet-spoke1-prod --address-prefix 10.1.0.0/16 \
  --subnet-name prod-web-subnet --subnet-prefix 10.1.1.0/24

az network vnet create --resource-group $RG --name vnet-spoke2-mgmt --address-prefix 10.2.0.0/16 \
  --subnet-name mgmt-subnet --subnet-prefix 10.2.1.0/24

echo "Configuring ASGs & NSGs..."
az network asg create --resource-group $RG --name asg-prod-web --location $LOC
az network asg create --resource-group $RG --name asg-mgmt-jumpbox --location $LOC

az network nsg create --resource-group $RG --name vm-spoke1-prodNSG
az network nsg create --resource-group $RG --name nsg-spoke2-mgmt

az network nsg rule create --resource-group $RG --nsg-name vm-spoke1-prodNSG \
  --name default-allow-ssh --priority 100 \
  --source-asgs asg-mgmt-jumpbox --destination-asgs asg-prod-web \
  --destination-port-ranges 22 --protocol Tcp --access Allow --direction Inbound

az network nsg rule create --resource-group $RG --nsg-name vm-spoke1-prodNSG \
  --name Deny-All-Other-Inbound --priority 4000 \
  --source-address-prefixes '*' --destination-address-prefixes '*' \
  --destination-port-ranges '*' --protocol '*' --access Deny --direction Inbound

az network vnet subnet update --resource-group $RG --vnet-name vnet-spoke1-prod \
  --name prod-web-subnet --network-security-group vm-spoke1-prodNSG

az network vnet subnet update --resource-group $RG --vnet-name vnet-spoke2-mgmt \
  --name mgmt-subnet --network-security-group nsg-spoke2-mgmt

echo "Deploying VMs..."
az vm create --resource-group $RG --name vm-hub-nva \
  --vnet-name vnet-hub --subnet nva-subnet \
  --private-ip-address 10.0.2.4 --public-ip-address "" \
  --image Ubuntu2204 --size Standard_B1s \
  --admin-username azureuser --generate-ssh-keys

NIC_ID=$(az vm show -g $RG -n vm-hub-nva --query 'networkProfile.networkInterfaces[0].id' -o tsv)
az network nic update --ids $NIC_ID --ip-forwarding true

az vm run-command invoke -g $RG -n vm-hub-nva --command-id RunShellScript \
  --scripts "sudo sysctl -w net.ipv4.ip_forward=1"

az vm create --resource-group $RG --name vm-spoke1-prod \
  --vnet-name vnet-spoke1-prod --subnet prod-web-subnet \
  --asgs asg-prod-web --public-ip-address "" \
  --image Ubuntu2204 --size Standard_B1s \
  --admin-username azureuser --generate-ssh-keys

az vm create --resource-group $RG --name vm-spoke2-mgmt \
  --vnet-name vnet-spoke2-mgmt --subnet mgmt-subnet \
  --asgs asg-mgmt-jumpbox --public-ip-address "" \
  --image Ubuntu2204 --size Standard_B1s \
  --admin-username azureuser --generate-ssh-keys

echo "Configuring Peering..."
az network vnet peering create -g $RG -n hub-to-spoke1 --vnet-name vnet-hub \
  --remote-vnet vnet-spoke1-prod --allow-vnet-access --allow-forwarded-traffic

az network vnet peering create -g $RG -n spoke1-to-hub --vnet-name vnet-spoke1-prod \
  --remote-vnet vnet-hub --allow-vnet-access --allow-forwarded-traffic

az network vnet peering create -g $RG -n hub-to-spoke2 --vnet-name vnet-hub \
  --remote-vnet vnet-spoke2-mgmt --allow-vnet-access --allow-forwarded-traffic

az network vnet peering create -g $RG -n spoke2-to-hub --vnet-name vnet-spoke2-mgmt \
  --remote-vnet vnet-hub --allow-vnet-access --allow-forwarded-traffic

echo "Configuring UDRs..."
az network route-table create --resource-group $RG --name rt-spoke-to-nva --disable-bgp-route-propagation false

az network route-table route create -g $RG --route-table-name rt-spoke-to-nva -n Route-To-Spoke1 \
  --address-prefix 10.1.0.0/16 --next-hop-type VirtualAppliance --next-hop-ip-address 10.0.2.4

az network route-table route create -g $RG --route-table-name rt-spoke-to-nva -n Route-To-Spoke2 \
  --address-prefix 10.2.0.0/16 --next-hop-type VirtualAppliance --next-hop-ip-address 10.0.2.4

az network vnet subnet update -g $RG --vnet-name vnet-spoke1-prod -n prod-web-subnet --route-table rt-spoke-to-nva
az network vnet subnet update -g $RG --vnet-name vnet-spoke2-mgmt -n mgmt-subnet --route-table rt-spoke-to-nva

echo "Deployment complete!"

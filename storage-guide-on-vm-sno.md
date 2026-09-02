This file summarizes how to create a Storage on SNO running on VM for nico.
---
Introduction:

Nico requires Storage provisioner (required). 
The PostgreSQL, Vault, NATS, and Temporal PVCs request the cluster's default StorageClass (charts set storageClass: null), so the cluster must have one backed by a dynamic RWO provisioner.

Without this, the `make deploy-cloud-infra` will be stuck because no infra won't be deployed properly

This document summarizes the exact steps that should be taken to install a Light-Weight LLVM storage on SNO run in VM.

0. Prerequisite: Create the disk (100Gb) via Virt Manager - add a new hardware of type Storage.
After this step, connect to the SNO via ssh / oc debug command and run '
`lsblk` - you should see an unformatted device

# 1a. Create the namespace: `oc create namespace openshift-storage`
# 1b. Create OperatorGroup
```
  oc apply -f - <<'EOF'
  apiVersion: operators.coreos.com/v1
  kind: OperatorGroup
  metadata:
    name: openshift-storage-operatorgroup
    namespace: openshift-storage
  spec:
    targetNamespaces:
      - openshift-storage
  EOF
```
This resource can be also applied by `oc apply -f storage/1b-operator-group.yaml`
# 1c. Subscribe to LVMS
```
oc apply -f - <<'EOF'
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: lvms-operator
    namespace: openshift-storage
  spec:
    channel: stable-4.22
    name: lvms-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
    installPlanApproval: Automatic
  EOF
```
Alternative: `oc apply -f storage/1c-lvms-subscription.yaml`

# 1d. Wait for the operator pod to be ready (takes ~2 min)
oc rollout status deployment/lvms-operator -n openshift-storage --timeout=5m

Step 2 — Create the LVMCluster on the disk. In this example it's /dev/vdb (can be seen by `lsblk`)

```
oc apply -f - <<'EOF'
  apiVersion: lvm.topolvm.io/v1alpha1
  kind: LVMCluster
  metadata:
    name: lvmcluster
    namespace: openshift-storage
  spec:
    storage:
      deviceClasses:
        - name: vg1
          default: true
          deviceSelector:
            paths:
              - /dev/vdb
          thinPoolConfig:
            name: thin-pool-1
            sizePercent: 90
            overprovisionRatio: 10
  EOF
```
Alternative: `oc apply -f storage/2-lvm-cluster.yaml`

# Wait for LVMS to initialize the volume group and create the StorageClass
# This takes ~1-2 min. Watch until STATUS shows Ready:
```oc get lvmcluster -n openshift-storage -w```


# Confirm
oc get storageclass

The answer should include lvms-vg1 (default) in the output. At that point the pending PVCs in nico-rest will bind automatically
We can watch them with:
```
oc get pvc -n nico-rest -w
```
Once both PVCs show Bound, the Crunchy PG pods will start and the Temporal schema job will stop failing.
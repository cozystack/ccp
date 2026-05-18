# Provider CLI reference for cozystack:talos-reset

Per-provider command sets the skill emits in Phases 5–7. Each provider section lists: snapshot, terminate, relaunch, reattach. Operator runs them; skill never auto-executes without approval.

All examples use `<PLACEHOLDER>` for runtime-resolved values. The skill substitutes from `state.inventory.nodes[]`, snapshot files under `<config-dir>/talos-reset/<node>/`, and provider-specific lookups.

## OCI (Oracle Cloud Infrastructure)

### Snapshot (Phase 3)

```bash
NODE=<node-name>
OCID=<instance-ocid>
SNAP="$CONFIG_DIR/talos-reset/$NODE"
mkdir -p "$SNAP"

oci compute instance get --instance-id "$OCID" > "$SNAP/instance.json"
oci compute volume-attachment list --instance-id "$OCID" > "$SNAP/volume-attachments.json"
oci compute vnic-attachment list --instance-id "$OCID" > "$SNAP/vnic-attachments.json"

for vnic_ocid in $(jq --raw-output '.data[].id' < "$SNAP/vnic-attachments.json"); do
  oci network vnic get --vnic-id "$vnic_ocid" > "$SNAP/vnic-${vnic_ocid##*.}.json"
done
```

### Terminate (Phase 5)

```bash
oci compute instance terminate \
  --instance-id "$OCID" \
  --preserve-boot-volume false \
  --force

# Wait for TERMINATED
until [ "$(oci compute instance get --instance-id "$OCID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)" = "TERMINATED" ]; do
  sleep 10
done
```

### Relaunch (Phase 6)

```bash
SHAPE=$(jq --raw-output '.data.shape' < "$SNAP/instance.json")
SHAPE_CONFIG=$(jq --compact-output '.data."shape-config"' < "$SNAP/instance.json")
AD=$(jq --raw-output '.data."availability-domain"' < "$SNAP/instance.json")
PRIMARY_SUBNET=$(jq --raw-output '.data."subnet-id" // (.data[0]."subnet-id")' < "$SNAP/vnic-attachments.json")

NEW_OCID=$(oci compute instance launch \
  --shape "$SHAPE" \
  --shape-config "$SHAPE_CONFIG" \
  --image-id "$COZYSTACK_TUNED_IMAGE_OCID" \
  --launch-mode PARAVIRTUALIZED \
  --availability-domain "$AD" \
  --subnet-id "$PRIMARY_SUBNET" \
  --hostname-label "$NODE" \
  --wait-for-state RUNNING \
  --query 'data.id' --raw-output)

NEW_PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$NEW_OCID" \
  --query 'data[0]."public-ip"' --raw-output)
```

### Reattach (Phase 6)

```bash
# Data volume (single preserved per node in the canonical cozystack layout)
PRESERVED_VOLUME=$(jq --raw-output '.data[] | select(."is-pv-encryption-in-transit-enabled" == false) | ."volume-id"' \
  < "$SNAP/volume-attachments.json" | head -1)

oci compute volume-attachment attach \
  --instance-id "$NEW_OCID" \
  --volume-id "$PRESERVED_VOLUME" \
  --type iscsi --wait-for-state ATTACHED

# Secondary VNIC (carries VIP-link static IPv4 on VLAN)
SECONDARY_VNIC=$(jq --compact-output '.data[] | select(."is-primary" == false)' \
  < "$SNAP/vnic-attachments.json" | head -1)

if [ -n "$SECONDARY_VNIC" ]; then
  VLAN_ID=$(jq --raw-output '."vlan-id"' <<<"$SECONDARY_VNIC")
  cat > "$SNAP/vnic-secondary.json" <<EOF
{"vlanId": "$VLAN_ID", "displayName": "${NODE}-vlan-vip"}
EOF
  oci compute vnic-attachment create \
    --instance-id "$NEW_OCID" \
    --create-vnic-details "file://$SNAP/vnic-secondary.json"
fi
```

OCI-specific gotchas:

- `--launch-mode PARAVIRTUALIZED` is mandatory for cozystack-tuned Custom Images imported as QCOW2. `NATIVE` mode requires UEFI-bootable images; cozystack's nocloud-amd64 raw format only boots in paravirtualized mode.
- Ephemeral public IPs change on relaunch. If the operator has a Reserved IP they want to keep, the skill flags it during Phase 4 plan presentation and adds an extra `oci network public-ip update` step. Otherwise the new IP is captured in Phase 6 and state.yaml updated.
- Secondary VNICs on VLANs cannot be cloned 1:1 — the `vlan-id` is preserved, but the VNIC's own OCID is new. Per-node VIP-link static IPv4 (from `state.cluster.vip.per_node[<node>]`) must be re-applied via Talos machine-config; the skill does NOT preserve the per-VNIC IP assignment, only the VLAN membership.

## AWS (Elastic Compute Cloud)

### Snapshot (Phase 3)

```bash
NODE=<node-name>
IID=<instance-id>
SNAP="$CONFIG_DIR/talos-reset/$NODE"
mkdir -p "$SNAP"

aws ec2 describe-instances --instance-ids "$IID" > "$SNAP/instance.json"
aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$IID" \
  > "$SNAP/volumes.json"
aws ec2 describe-network-interfaces \
  --filters "Name=attachment.instance-id,Values=$IID" \
  > "$SNAP/enis.json"
```

### Terminate (Phase 5)

```bash
# Detach the data volume FIRST — AWS does not let you preserve a non-root volume
# attached to a terminated instance unless DeleteOnTermination is false.
DATA_VOLUMES=$(jq --raw-output '.Volumes[] | select(.Attachments[0].Device != "/dev/sda1" and .Attachments[0].Device != "/dev/xvda") | .VolumeId' < "$SNAP/volumes.json")

for vol in $DATA_VOLUMES; do
  aws ec2 detach-volume --volume-id "$vol" --force
  aws ec2 wait volume-available --volume-ids "$vol"
done

aws ec2 terminate-instances --instance-ids "$IID"
aws ec2 wait instance-terminated --instance-ids "$IID"
```

### Relaunch (Phase 6)

```bash
INSTANCE_TYPE=$(jq --raw-output '.Reservations[0].Instances[0].InstanceType' < "$SNAP/instance.json")
SUBNET_ID=$(jq --raw-output '.Reservations[0].Instances[0].SubnetId' < "$SNAP/instance.json")
SG_IDS=$(jq --raw-output '[.Reservations[0].Instances[0].SecurityGroups[].GroupId] | join(",")' < "$SNAP/instance.json")
KEY_NAME=$(jq --raw-output '.Reservations[0].Instances[0].KeyName // ""' < "$SNAP/instance.json")
AZ=$(jq --raw-output '.Reservations[0].Instances[0].Placement.AvailabilityZone' < "$SNAP/instance.json")

NEW_IID=$(aws ec2 run-instances \
  --image-id "$COZYSTACK_TUNED_AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids $SG_IDS \
  ${KEY_NAME:+--key-name "$KEY_NAME"} \
  --placement "AvailabilityZone=$AZ" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NODE}]" \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$NEW_IID"
NEW_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$NEW_IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
```

### Reattach (Phase 6)

```bash
for vol_record in $(jq --compact-output '.Volumes[] | select(.Attachments[0].Device != "/dev/sda1" and .Attachments[0].Device != "/dev/xvda")' < "$SNAP/volumes.json"); do
  VOL_ID=$(jq --raw-output '.VolumeId' <<<"$vol_record")
  DEVICE=$(jq --raw-output '.Attachments[0].Device' <<<"$vol_record")
  aws ec2 attach-volume --volume-id "$VOL_ID" --instance-id "$NEW_IID" --device "$DEVICE"
done

# Secondary ENIs (typically not used in the canonical cozystack AWS layout — primary ENI
# carries everything via SG rules — but if present:
for eni_record in $(jq --compact-output '.NetworkInterfaces[] | select(.Attachment.DeviceIndex > 0)' < "$SNAP/enis.json"); do
  ENI_ID=$(jq --raw-output '.NetworkInterfaceId' <<<"$eni_record")
  DEV_IDX=$(jq --raw-output '.Attachment.DeviceIndex' <<<"$eni_record")
  aws ec2 attach-network-interface --network-interface-id "$ENI_ID" \
    --instance-id "$NEW_IID" --device-index "$DEV_IDX"
done
```

AWS-specific gotchas:

- `aws ec2 terminate-instances` deletes any volume with `DeleteOnTermination: true` (the root volume by default). Detach data volumes FIRST.
- Elastic IPs survive terminate but disassociate. Re-associate post-relaunch: `aws ec2 associate-address --instance-id "$NEW_IID" --allocation-id "$EIP_ALLOC_ID"`.
- ENI security-group memberships travel with the ENI on re-attach.

## GCP (Google Compute Engine)

### Snapshot (Phase 3)

```bash
NODE=<node-name>
ZONE=<zone>
SNAP="$CONFIG_DIR/talos-reset/$NODE"
mkdir -p "$SNAP"

gcloud compute instances describe "$NODE" --zone="$ZONE" --format=json > "$SNAP/instance.json"
gcloud compute disks list --filter="users:zones/$ZONE/instances/$NODE" --format=json \
  > "$SNAP/disks.json"
```

### Terminate (Phase 5)

```bash
# Detach data disks (keep them around — delete defaults to false on attached disks not marked autoDelete)
DATA_DISKS=$(jq --raw-output '.[] | select(.boot != true) | .name' < "$SNAP/disks.json")

for disk in $DATA_DISKS; do
  gcloud compute instances detach-disk "$NODE" --disk="$disk" --zone="$ZONE"
done

gcloud compute instances delete "$NODE" --zone="$ZONE" --quiet
```

### Relaunch (Phase 6)

```bash
MACHINE_TYPE=$(jq --raw-output '.machineType | split("/")[-1]' < "$SNAP/instance.json")
NETWORK=$(jq --raw-output '.networkInterfaces[0].network | split("/")[-1]' < "$SNAP/instance.json")
SUBNET=$(jq --raw-output '.networkInterfaces[0].subnetwork | split("/")[-1]' < "$SNAP/instance.json")
TAGS=$(jq --raw-output '.tags.items // [] | join(",")' < "$SNAP/instance.json")

gcloud compute instances create "$NODE" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --image="$COZYSTACK_TUNED_IMAGE" \
  --image-project="$IMAGE_PROJECT" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  ${TAGS:+--tags="$TAGS"} \
  --no-restart-on-failure

NEW_PUBLIC_IP=$(gcloud compute instances describe "$NODE" --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
```

### Reattach (Phase 6)

```bash
for disk in $DATA_DISKS; do
  gcloud compute instances attach-disk "$NODE" --disk="$disk" --zone="$ZONE"
done
```

GCP-specific gotchas:

- `gcloud compute instances delete` with `--keep-disks=data` preserves all non-boot disks automatically. Less manual detach dance than AWS.
- Public IPs change on delete+create unless a Reserved IP was promoted.
- Cloud NAT'd VMs do not have a public IP on the interface — the Phase 4.5 NAT-signature research in the next bootstrap handles certSANs.

## Hetzner Cloud

### Snapshot (Phase 3)

```bash
NODE=<node-name>
SRV=<server-id>
SNAP="$CONFIG_DIR/talos-reset/$NODE"
mkdir -p "$SNAP"

hcloud server describe "$SRV" --output json > "$SNAP/server.json"
hcloud volume list --selector="server.id=$SRV" --output json > "$SNAP/volumes.json"
```

### Terminate (Phase 5)

```bash
DATA_VOLUMES=$(jq --raw-output '.[].id' < "$SNAP/volumes.json")

for vol in $DATA_VOLUMES; do
  hcloud volume detach "$vol"
done

hcloud server delete "$SRV"
```

### Relaunch (Phase 6)

```bash
SERVER_TYPE=$(jq --raw-output '.server_type.name' < "$SNAP/server.json")
LOCATION=$(jq --raw-output '.datacenter.location.name' < "$SNAP/server.json")
SSH_KEYS=$(jq --raw-output '[.public_net.ssh_keys[].name] | join(",")' < "$SNAP/server.json")

NEW_SRV=$(hcloud server create \
  --name "$NODE" \
  --type "$SERVER_TYPE" \
  --location "$LOCATION" \
  --image "$COZYSTACK_TUNED_IMAGE_NAME" \
  ${SSH_KEYS:+--ssh-key "$SSH_KEYS"} \
  --output json | jq --raw-output '.server.id')

NEW_PUBLIC_IP=$(hcloud server describe "$NEW_SRV" --output json \
  | jq --raw-output '.public_net.ipv4.ip')
```

### Reattach (Phase 6)

```bash
for vol in $DATA_VOLUMES; do
  hcloud volume attach "$vol" --server "$NEW_SRV"
done

# Hetzner doesn't have native VLAN secondary VNICs — vSwitch attachments live at the Network layer.
# If the server was on a Network, re-attach:
NETWORK_ID=$(jq --raw-output '.private_net[0].network // empty' < "$SNAP/server.json")
if [ -n "$NETWORK_ID" ]; then
  PRIVATE_IP=$(jq --raw-output '.private_net[0].ip' < "$SNAP/server.json")
  hcloud server attach-to-network "$NEW_SRV" --network "$NETWORK_ID" --ip "$PRIVATE_IP"
fi
```

Hetzner-specific gotchas:

- Dedicated servers (Robot) are a different product entirely — `hcloud` only manages Cloud servers. For dedicated, the reset path involves Hetzner Robot's web UI (no usable CLI) — out of scope for this skill in v1; surface a manual checklist instead.
- vSwitch + VLAN setup is configured at the Network level on Hetzner Cloud — re-attach preserves VLAN membership.
- Hetzner doesn't have an "ephemeral vs reserved IP" distinction the same way; the new server gets a new public IPv4. RobotLB (if used) needs `ROBOTLB_HCLOUD_TOKEN` re-targeted at the new server IDs after relaunch.

## Generic / unknown provider

If the operator is on a provider the skill doesn't have a CLI section for, refuse with:

```text
talos-reset — provider not supported

  detected:  $PROVIDER
  supported: oci / aws / gcp / hetzner (Hetzner Cloud only, not Robot)

  This skill needs provider-specific CLI orchestration to terminate
  + preserve disks + relaunch + reattach. Without that, the safe
  path is manual:

  1. Snapshot your instance's volume-attachment + VNIC config via your
     provider's console / CLI of choice.
  2. Detach data volumes (do NOT delete on terminate).
  3. Terminate the instance.
  4. Create a new instance from the cozystack-tuned image.
  5. Re-attach the data volumes + any secondary VNICs.
  6. Update <config-dir>/.state.yaml inventory.nodes[*].public_ip
     with the new IPs.
  7. Re-invoke /cozystack:talos-bootstrap.

  PRs welcome to add your provider — see plugins/cozystack/skills/talos-reset/references/provider-cli.md.
```

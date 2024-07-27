# Authenticate and set up environment
gcloud auth list

gcloud config set compute/zone $ZONE

gcloud config set project $DEVSHELL_PROJECT_ID

export PROJECT_ID=$(gcloud info --format='value(config.project)')

# Create a GKE cluster
gcloud container clusters create gmp-cluster --num-nodes=1 --zone $ZONE

# Create a logging metric for stopped VMs
gcloud logging metrics create stopped-vm --log-filter='resource.type="gce_instance" protoPayload.methodName="v1.compute.instances.stop"' --description="Metric for stopped VMs"

# Create a Pub/Sub notification channel for Pinaki
cat > cp-channel.json <<EOF_CP
{
  "type": "pubsub",
  "displayName": "pinaki-channel",
  "description": "subscribe to pinaki-channel",
  "labels": {
    "topic": "projects/$DEVSHELL_PROJECT_ID/topics/notificationTopic"
  }
}
EOF_CP

gcloud beta monitoring channels create --channel-content-from-file=cp-channel.json

email_channel=$(gcloud beta monitoring channels list)
channel_id=$(echo "$email_channel" | grep -oP 'name: \K[^ ]+' | head -n 1)

# Create an alerting policy for stopped VMs with Pinaki reference
cat > stopped-vm-cp-policy.json <<EOF_CP
{
  "displayName": "stopped vm",
  "documentation": {
    "content": "Documentation content for the stopped vm alert policy created by Pinaki",
    "mime_type": "text/markdown"
  },
  "userLabels": {},
  "conditions": [
    {
      "displayName": "Log match condition",
      "conditionMatchedLog": {
        "filter": "resource.type=\"gce_instance\" protoPayload.methodName=\"v1.compute.instances.stop\""
      }
    }
  ],
  "alertStrategy": {
    "notificationRateLimit": {
      "period": "300s"
    },
    "autoClose": "3600s"
  },
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "$channel_id"
  ]
}
EOF_CP

gcloud alpha monitoring policies create --policy-from-file=stopped-vm-cp-policy.json

# Stop a VM instance
export ZONE2=us-central1-a
gcloud compute instances stop instance1 --zone=$ZONE2 --quiet

sleep 45

# List GKE clusters
gcloud container clusters list

# Get credentials for the cluster
gcloud container clusters get-credentials gmp-cluster

# Deploy applications to GKE
kubectl create ns pinaki-test

kubectl -n pinaki-test apply -f https://storage.googleapis.com/spls/gsp091/gmp_flask_deployment.yaml

kubectl -n pinaki-test apply -f https://storage.googleapis.com/spls/gsp091/gmp_flask_service.yaml

# Get services
kubectl get services -n pinaki-test

# Create a logging metric for hello-app errors
gcloud logging metrics create hello-app-error \
    --description="Metric for hello-app errors" \
    --log-filter='severity=ERROR
resource.labels.container_name="hello-app"
textPayload: "ERROR: 404 Error page not found"'

# Create an alerting policy for hello-app errors with Pinaki reference
cat > techcps.json <<'EOF_CP'
{
  "displayName": "log based metric alert by Pinaki",
  "userLabels": {},
  "conditions": [
    {
      "displayName": "New condition",
      "conditionThreshold": {
        "filter": 'metric.type="logging.googleapis.com/user/hello-app-error" AND resource.type="global"',
        "aggregations": [
          {
            "alignmentPeriod": "120s",
            "crossSeriesReducer": "REDUCE_SUM",
            "perSeriesAligner": "ALIGN_DELTA"
          }
        ],
        "comparison": "COMPARISON_GT",
        "duration": "60s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "604800s"
  },
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [],
  "severity": "SEVERITY_UNSPECIFIED"
}
EOF_CP

gcloud alpha monitoring policies create --policy-from-file=techcps.json

# Trigger the alert by making requests to the service
timeout 120 bash -c -- 'while true; do curl $(kubectl get services -n pinaki-test -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}')/error; sleep $((RANDOM % 4)) ; done'

#
# requires a k8s cluster running with cert-manager running in it
# requires kind https://github.com/kubernetes-sigs/kind
#

validateMetrics() {
    metrics=$1
    expectedVal=$2    

    raw=$(curl --silent http://localhost:8080/metrics | grep "$metrics")

    if [ "$raw" == "" ]; then
      echo "TEST FAILURE: $metrics" 
      echo "  Unable to find metrics string"
      return 0
    fi

    if [ "$expectedVal" == "" ]; then 
      echo "TEST SUCCESS: $metrics found.  Not testing expected val."
      return 0
    fi

    val=${raw#* }
    valInDays=$(awk "BEGIN {printf \"%.0f\", $val / (24 * 60 * 60)}")

    if [ "$expectedVal" -ne "$valInDays" ]; then
      echo "TEST FAILURE: $metrics"
      echo "  Expected  : $expectedVal"
      echo "  Raw       : $raw"
      echo "  Val       : $val"
      echo "  ValInDays : $valInDays"
    else 
      echo "TEST SUCCESS: $metrics"
    fi
}

KIND_CLUSTER_NAME=cert-exporter
CONFIG_PATH=cert-exporter.kubeconfig

echo -n "Create cluster"
kind create cluster --name=$KIND_CLUSTER_NAME --kubeconfig=$CONFIG_PATH

kubectl --kubeconfig=$CONFIG_PATH create namespace cert-manager
kubectl --kubeconfig=$CONFIG_PATH label namespace cert-manager certmanager.k8s.io/disable-validation=true
kubectl --kubeconfig=$CONFIG_PATH apply -f https://github.com/jetstack/cert-manager/releases/download/v0.14.0/cert-manager.yaml

kubectl --kubeconfig=$CONFIG_PATH wait --for=condition=available deploy --all -n cert-manager --timeout=3m

kubectl --kubeconfig=$CONFIG_PATH apply -f ./certs.yaml

GO111MODULE=on go mod vendor
go build ../../main.go

echo "** Testing Label Selector"
# run exporter
./main --kubeconfig=$CONFIG_PATH \
    --secrets-annotation-selector='cert-manager.io/certificate-name' \
    --secrets-annotation-selector='test' \
    --secrets-include-glob='*.crt' \
    --alsologtostderr &
pid=$!
sleep 10

validateMetrics 'cert_exporter_secret_expires_in_seconds{cn="example.com",issuer="example.com",key_name="ca.crt",secret_name="selfsigned-cert-tls",secret_namespace="cert-manager-test"}' 100
validateMetrics 'cert_exporter_secret_expires_in_seconds{cn="hms-test",issuer="hms-test",key_name="test.crt",secret_name="test",secret_namespace="default"}'

# kill exporter
echo "** Killing $pid"
kill $pid

echo "** Testing Label Selector And Namespace"
# run exporter
./main --kubeconfig=$CONFIG_PATH \
    --secrets-annotation-selector='cert-manager.io/certificate-name' \
    --secrets-namespace='cert-manager-test' \
    --secrets-include-glob='*.crt' \
    --alsologtostderr &
pid=$!
sleep 10

validateMetrics 'cert_exporter_secret_expires_in_seconds{cn="example.com",issuer="example.com",key_name="ca.crt",secret_name="selfsigned-cert-tls",secret_namespace="cert-manager-test"}' 100

# kill exporter
echo "** Killing $pid"
kill $pid

echo "** Testing Label Selector And Exclude Glob"
# run exporter
./main --kubeconfig=$CONFIG_PATH \
    --secrets-annotation-selector='cert-manager.io/certificate-name' \
    --secrets-namespace='cert-manager-test' \
    --secrets-exclude-glob='*.key' \
    --alsologtostderr &
pid=$!
sleep 10

validateMetrics 'cert_exporter_secret_expires_in_seconds{cn="example.com",issuer="example.com",key_name="ca.crt",secret_name="selfsigned-cert-tls",secret_namespace="cert-manager-test"}' 100

# kill exporter
echo "** Killing $pid"
kill $pid

rm ./main
kind delete cluster --name=$KIND_CLUSTER_NAME --kubeconfig=$CONFIG_PATH
rm $CONFIG_PATH

# istio-buffering

The files in this repo should be run on a fresh K8s cluster to avoid conflicts with existing configuration.

## Standing up

```
# Install Istio Helm charts, apply Gateway and Waypoint configuration; note:
#   - the istiod-values.yaml meshConfig turns on ALL of the Envoy metrics
#   - Gateway and Waypoint are configured to log at "trace" level
./install-istio.sh

# Add our sample service in the "caddy" namespace; this creates:
#   - svc/caddy-service listens on port 9999, uses the Waypoint
#   - deploy/caddy and configmap/caddy:
#     - uses an initContainer to create a 1GB test file of random data
#     - Caddy will create a self-signed cert, and is configured to accept any TLS hostname
#  - XListenerSet, TLSRoute wiring for TLS hostname "caddy.internal"
kubectl apply -f caddy-service.yaml

kubectl apply -f envoyfilters.yaml
```

## The problem

When we have a slow client (e.g. 1Mbps bandwidth), the Application successfully sends out 70-80MB of data within the first 10-15 seconds. The bytes appear to be buffered somewhere, but we can't identify where.

This causes issues for our real world Application because from the Application's perspective it has written 70+MB to the socket. The 70+MB then takes ~10 minutes to flush out to the slow client at 1Mbps, during which time the Server has no feedback as to what is happening (other than the socket has not been reset). Without feedback, the only workaround for the Application is to increase timeouts massively (e.g. to 10+ minutes) to wait and hope that the data made it through.

## Reproduction

In the above setup, Caddy has been substituted for our real application (call this the "Application").

We can use `curl` to simulate a slow client:

```
gatewayIP=$(kubectl get svc -n istio-gateway istio-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Note the --limit-rate, and --http1.1
curl -vk https://$gatewayIP:9999/testdata.bin --output /dev/null --limit-rate 125k --http1.1
```

The `--http1.1` is significant. `curl` defaults to HTTP/2 and the built-in flow control avoids this issue. However, our real world Application doesn't speak HTTP - it has its own protocol that relies on TCP flow control. Using `--http1.1` with Caddy simulates this behaviour since HTTP/1.1 also has no flow control.

## Observations

### Wireshark
Firstly, we observe with tcpdump and Wireshark that ~73MB of data from the Application is being sent over the wire to the Waypoint within the first 15 seconds.
```
# Wireshark

# shell into the caddy pod and `apk add tcpdump`

# This will run `tcpdump` in the caddy pod, writing to STDOUT which is then piped into `wireshark` on your local machine (assumes Mac path)
kubectl exec -n caddy $(kubectl get -n caddy pod -o jsonpath='{.items[0].metadata.name}') -- tcpdump -i any -w - -U -s 128 port 443 | /Applications/Wireshark.app/Contents/MacOS/Wireshark -k -i -
```

In Wireshark, in the Statistics -> Conversations view, select TCP and we see this:

### Envoy stats

The setup above installed the sample Prometheus chart. Access it using `istioctl dashboard prometheus`, then we used this URL: http://localhost:9090/query?g0.expr=envoy_tcp_downstream_cx_tx_bytes_buffered%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_cluster_upstream_cx_rx_bytes_buffered%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_server_memory_allocated&g0.show_tree=0&g0.tab=graph&g0.range_input=10m&g0.res_type=auto&g0.res_density=high&g0.display_mode=lines&g0.show_exemplars=0&g1.expr=envoy_tcp_downstream_cx_tx_bytes_total%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_cluster_upstream_cx_rx_bytes_total%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_server_memory_allocated&g1.show_tree=0&g1.tab=graph&g1.range_input=10m&g1.res_type=auto&g1.res_density=medium&g1.display_mode=lines&g1.show_exemplars=0


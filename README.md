# istio-buffering

## Architecture

Our Istio setup is crudely: `Client <--> Gateway <--> Waypoint <--> Application`

## The problem

When we have a slow client (e.g. 1Mbps bandwidth) and the Application wishes to send large amounts of data to the client, e.g. 500MB, the Application is able to write 70-80MB of data to its socket within the first 10-15 seconds. The client is unable to receive data this quickly and the bytes appear to be buffered somewhere, but we can't identify where.

This causes issues for the Application because from the Application's perspective it has written 70+ MB to the socket. The 70+ MB then takes ~10 minutes to flush out to the slow client at 1Mbps, during which time the Application has no feedback as to what is happening (other than the socket has not been reset or errored). The Application has timeouts configured for a response from the client, and also timeouts on being able to write further bytes to the socket. These timeouts are in the order of 5 minutes and 1 minute so they are both easily triggered since, from the Application's POV, nothing is happening for ~10 minutes.

Without feedback from the socket, the only workaround for the Application is to increase timeouts massively (e.g. to 10+ minutes) to wait and hope that the data made it through.

## Reproduction

The files in this repo provide a simplified reproduction of the problem, standing up a Gateway, Waypoint, and Caddy in place of the Application.

The files in this repo should be run on a fresh K8s cluster to avoid conflicts with existing configuration.

### Standing up

```
# Install Istio Helm charts, apply Gateway and Waypoint configuration; note:
#   - the istiod-values.yaml meshConfig turns on ALL of the Envoy metrics
#   - Gateway and Waypoint are configured to log at "trace" level
#   - Istio's sample Prometheus chart is installed to provide convenient access to metrics
./install-istio.sh

# Add our sample service in the "caddy" namespace; this creates:
#   - svc/caddy-service listens on port 9999, uses the Waypoint
#   - deploy/caddy and configmap/caddy:
#     - uses an initContainer to create a 1GB test file of random data
#     - Caddy will create a self-signed cert, and is configured to accept any TLS hostname
#  - XListenerSet, TLSRoute wiring for TLS hostname "caddy.internal"
kubectl apply -f caddy-service.yaml

# Apply an EnvoyFilter that adjusts `per_connection_buffer_limit_bytes`, `initial_stream_window_size` and `initial_connection_window_size`
# These values are the same values we use in Production
kubectl apply -f envoyfilters.yaml
```

### Reproducing and observing the issue

We can use `curl` to simulate a slow client:

```
gatewayIP=$(kubectl get svc -n istio-gateway istio-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -vk https://$gatewayIP:9999/testdata.bin --output /dev/null --limit-rate 125k --http1.1
```

Note the `--limit-rate`, and `--http1.1`.

`curl` defaults to HTTP2 and HTTP2's built-in flow control avoids this issue. However, our real world Application doesn't speak HTTP - it has its own protocol that relies on TCP flow control. Using `--http1.1` with Caddy simulates this behaviour since HTTP/1.1 also has no flow control.

### Observations

#### Wireshark
Firstly, we observe with tcpdump and Wireshark that ~73MB of data from the Application is being sent over the wire to the Waypoint within the first 15 seconds.

Captured using:
```
# shell into the caddy pod and `apk add tcpdump`

# This will run `tcpdump` in the caddy pod, writing to STDOUT which is then piped into `wireshark` on your local machine (assumes Mac path)
kubectl exec -n caddy $(kubectl get -n caddy pod -o jsonpath='{.items[0].metadata.name}') -- tcpdump -i any -w - -U -s 128 port 443 | /Applications/Wireshark.app/Contents/MacOS/Wireshark -k -i -
```

In Wireshark, in the `Statistics -> Conversations` view, select `TCP` and we see this:
<img width="1604" height="574" alt="image" src="https://github.com/user-attachments/assets/705dd401-3707-430d-bd1b-d9ca7a2b9caf" />


### Envoy stats

The setup above installed the sample Prometheus chart. Access it using `istioctl dashboard prometheus`, then use [this URL](http://localhost:9090/query?g0.expr=envoy_tcp_downstream_cx_tx_bytes_buffered%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_cluster_upstream_cx_rx_bytes_buffered%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_server_memory_allocated&g0.show_tree=0&g0.tab=graph&g0.range_input=10m&g0.res_type=auto&g0.res_density=high&g0.display_mode=lines&g0.show_exemplars=0&g1.expr=envoy_tcp_downstream_cx_tx_bytes_total%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_cluster_upstream_cx_rx_bytes_total%7Bcluster_name%21%7E%22prometheus_stats%7C.*grpc%22%7D+or+envoy_server_memory_allocated&g1.show_tree=0&g1.tab=graph&g1.range_input=10m&g1.res_type=auto&g1.res_density=medium&g1.display_mode=lines&g1.show_exemplars=0). 

We don't really know what stats to be looking at, but these look interesting:

#### envoy_tcp_downstream_cx_tx_bytes_total, envoy_cluster_upstream_cx_rx_bytes_total, envoy_server_memory_allocated

If we focus on the highlighted time period, this graph seems to show that the Waypoint's `connect_originate` cluster quickly received ~68MB of data from the Application, and similarly the Gateway's `connect_originate` cluster has received ~33.5MB from the Waypoint. We know that in this timeframe the client would not have been able to receive more than 2MB.

<img width="1650" height="779" alt="image" src="https://github.com/user-attachments/assets/9a6895a9-e682-42f3-9e37-9d108fa3fca0" />

The graph also displays `envoy_server_memory_allocated` because when we looked at the next graph, the counters for bytes_buffered don't add up to anything near 30 or 60MB.

#### envoy_tcp_downstream_cx_tx_bytes_buffered, envoy_cluster_upstream_cx_rx_bytes_buffered

We went looking for where the data might be buffered to see what we should tune but these buffers don't sum to anywhere near 70MB. We suspect whatever is holding the buffered data is either not represented by available metrics, or we couldn't find the right metric (although we could not find any metric with a value that was 10s of MBs).

<img width="1655" height="765" alt="image" src="https://github.com/user-attachments/assets/ebe26da1-aedf-4267-9201-b0a59171c0e1" />


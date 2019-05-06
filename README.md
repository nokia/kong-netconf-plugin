Licensed under the BDS 3 Clause license

SPDX-License-Identifier: BSD-3-Clause

This plugin implements a simple and basic NETCONF (RFC6421) reverse proxy.

This plugin is not production grade currently.

# 1. Functionality
This plugin sits between the NETCONF client and the NETCONF servers and it distributes the different client requests to different NETCONF servers based on their <capability>. It is a kind of "back-2-back NETCONF agent": it manages separated <hello> negotiations towards the client and the servers, and consequently it manages the different session-ids, too.   

# 2. Installation
Requires: Kong version >= 1.0.3

The plugin uses, and so requires the additional LuaXML and lpty modules. You can install those via luarocks.

The plugin itself is a regular Kong plugin, so you can follow the relevant plugin installation instructions in the Kong documentation.

NETCONF uses SSH as a "Secure Transport Layer". This plugin does not implement an SSH server (towards the NETCONF client), or an SSH client (towards the NETCONF servers). It requires a standalone SSH server to manage the SSH session towards the client, and in turn it requries an SSH client that can manage an SSH session towards the NETCONF servers.

The plugin expects that it can read out the client's user name - with which the client logged into the SSH server - from a file named /tmp/netconfusers/<client port of the connection from the SSH server to Kong>. The plugin needs this user name information in order to be able to login with the same user into the NETCONF server.

In order to have the necessary SSH server and SSH client "around" we provide here the artefacts required for a Kubernetes based deployment. 

# 3. Configuration

Attribute                                | Description
----------------------------------------:| -----------
`config.max_msg_size`                    | The maximum size of a NETCONF message which is accepted from the client. Default: 4MB
`config.secret_prefix`                   | The prefix of the path where the plugin searches for the password or secret which is used to login into the selected upstream                                                | NETCONF server
`config.capability_upstream`             | The map that maps a capability of a NETCONF request to an upstream server
`config.capability_upstream.destination` | The upstream server's address. It should have the format: "address:port". If "port" is not configured then the default value is                                              | "830"
`config.capability_upstream.auth_method` | The authentication method that can be used to the upstream server. Possible values are: "password", "key".

You must configure at least one capability ("urn:ietf:params:netconf:base:1.1") with the relevant upstream server.   

# 4. Example deployment

In this repo we provide the manifests, config files and other artefacts that are required for a Kubernetes (what else?) based deployment.

```kong/Dockerfile```: installs lpty, LuaXML and OpenSSH client into the same container image with Kong 1.1.1

```kong/kong.conf```: a Kong configuration file that enables the new plugin

```kong/kong.yml```: the Kubernetes pod manifest to run the Kong container, which includes the lpty, LuaXML and OpenSSH client, and to run the OpenSSH Server

```kong/kong-config.yml```: declarative config of route, service and plugins for Kong. See https://docs.konghq.com/1.1.x/db-less-and-declarative-config/

```ssh-server/Dockerfile```: installs OpenSSH server, socat, and ss into the container image, and creates a "netconf" user

```ssh-server/netconfusers.sh```: the sshd will execute this script when the "netconf" subsystem is requested by the client. It performs 2 tasks: a) it writes the name of the user who logged in into a file on the shared volume so the Kong pluing can read it; b) it starts a TCP connection to the Kong container and maps stdin/stdout to the TCP connection with socat

```ssh-server/sshd.config```: the config for the sshd which makes the sshd execute the netconfusers.sh script when the "netconf" subsystem is requested by the client 

```ssh-server/startup.sh```: the entrypoint of the container

Build the container images with your favorite tool.

We use environment variables on the relevant places of the files. I.e. the files can be easily updated to align with your local environment with e.g. "envsubst".

The environment variables are the following:

KONG_CONTAINER_IMAGE: the image name of the Kong container as it should apper in a Pod manifest

KONG_NETCONF_LISTENER_PORT: the incoming port for Kong which is configured on the "netconfproxy" route in the kong/kong-config.yml (e.g. 18830)

KONG_SSH_LISTENER_PORT: the incoming port for Kong which is configured on the "netconfupstream" route in the kong/kong-config.yml (e.g. 38830)

PLUGIN_SECRET_PATH: it should have the same path like that configured with "config.secret_prefix" in the plugin config (see above, e.g. /tmp/password)

SSHD_CONTAINER_IMAGE: the image name of the sshd container as it should apper in a Pod manifest

SSHD_CONFIG_PATH: the absolute path of the ssh-server/sshd.config file in your environment (e.g. ${YOUR_PLUGIN_REPO}/ssh-server/sshd.config)

SSHD_PUBLIC_KEY_PATH: the absolute path of the public key file of which private pair is used by the NETCONF client to log into the OpenSSH server

KONG_CONFIG_PATH: the absolute path of the kong/kong.conf file in your environment (e.g. ${YOUR_PLUGIN_REPO}/kong/kong.config)

NECTONF_PLUGIN_PATH: the absolute path of the plugin/netconf directory in your environment (e.g. ${YOUR_PLUGIN_REPO}/plugin/netconf)

NETCONF_SERVER_SECRET: this shall be an absolute path to a file that contains the secret (e.g. password or private key) which can be used by the plugin to log into the NETCONF server

KONG_SERVICE_ROUTE_PLUGIN_CONFIG_PATH: the absolute path of the kong/kong-config.yml directory in your environment (e.g. ${YOUR_PLUGIN_REPO}/kong/kong-config.yml)

UPSTREAM_SERVER: IP address and port of the NETCONF server

We provide a Kubernetes manifest to deploy netopeer2 as NETCONF server, and to create the relevant K8s Service, too.

The final deployment will look like this:

```
                                                                                  +--------------------------------------------------------------+
                                                                                  |  Kong Pod                                                    |
                                                                                  |                                                              |
                                                                                  |     +-----------------------------------------------------+  |
                                                                                  |     |                                                     |  | 
                                                                                  |     |  Kong container                                     |  |
                                                                                  |     |                                                     |  |
                                                                                  |     |   +----------+             +-------------+          |  |
                                                                                  |     |   |          |             |             |          |  |
                                                                                  |     |   | netconf  | +-fork--->  | OpenSSH     |          |  |
                                                                                  |     |   | plugin   |             | Client      |          |  |
                                                                                  |     |   |          |             |             |          |  |
                                                                                  |     |   +----------+             +----------+--+          |  |
                                                                                  |     |   +------------------------+          |             |  |
                                                                                  |     |   |   nginx+OpenResty      |      localhost:38830   |  |
                                                                                  |     |   |                        | <--------+             |  |
                                                                                  |     |   +------------------------+                        |  |
                                                                                  |     +-----------------------------------------------------+  |
                                                                                  |           ^                   |                              |
                                                                                  |           |                   |                              |
                                                                                  |           |                   |                              |
                                                                                  |  localhost:18830   netconfupstream IP:830                    |
                                                                                  |           |                   |                              |
                                                                                  |           |                   |                              |
                                                                                  |           +                   |                              |
                                          +---------------+                       |    +-------------+            |                              |  +-----------------+   +-----------------+  
+-----------+                             |               |                       |    |             |            |                              |  |                 |   |                 |  
|           |                             | netconfproxy  |                       |    |  OpenSSH    |            |                              |  | netconfupstream |   | NETCONF         |  
| Client    |   +-netconfproxy IP:830-->  | Service       | +----Pod IP:8830------|>   |  Server     |            +------------------------------|->| Service         |-->| Server          |  
|           |                             |               |                       |    |  container  |                                           |  |                 |   |                 |  
|           |                             |               |                       |    |             |                                           |  |                 |   |                 |  
+-----------+                             +---------------+                       |    +-------------+                                           |  +-----------------+   +-----------------+  
                                                                                  |                                                              |
                                                                                  +--------------------------------------------------------------+

```

# TODO

Check and cover all operations and functionalities defined in the NETCONF RFC

Provide a Helm or kustomize based solution for the customization of the deployment manifests at /utils, instead of the current "environment variable" based one

# FAQ

## Why?

This is a totally valid question. It all started with a discussion in which there was a statement like "Kong does not support NETCONF". That sounded like a challenge at that time, and this plugin was born. Not because the author is religious about Kong, or something. Simply, it was a glove. But of course, it does not make any sense to write a plugin that just passes NETCONF messages back and forth. If we check NETCONF a bit closer it turns out that it is just a protocol for RPC, and actually it was designed with further extensibility in mind. So, in order to give some meaning to this nonsense project here the idea was: let's create a NETCONF reverse proxy that can distribute NETCONF messages to the upstream NETCONF servers based on the <capability> of the RPC request.
# Tokenman architecture

Tokenman is a runtime for native AI coding agents such as Claude Code and Codex, provided by model companies and run unmodified: it handles where they run, how they stay online, how people connect from any device, and how subscriptions are shared and metered. This is a conceptual map: the layers show responsibilities, not a deployment topology. All eight principles describe behavior live in production.

[Open the visual blueprint](https://tokenman.io/architecture) · [Security and isolation](security.md)

![Four layers: clients use the hub; the hub owns central data; nodes run sessions and dial out to the hub. Model requests cross the credential proxy to external providers.](assets/architecture.svg)

<!-- blueprint:layers -->
## Four layers

### 1 · Clients

- **Web app** — Chat with agents, manage sessions and read service health. [Learn more](member/quickstart.md).
- **Command line** — Use the fleet CLI and terminal to reach ongoing sessions. [Learn more](member/connect.md).

Clients connect to the hub through an encrypted entry.

### 2 · Application · the hub

- **Identity and access** — Sign-in, people, organizations and roles. [Learn more](admin/access.md).
- **Sessions** — Start, find and relay conversations to the node that runs them. [Learn more](member/usage.md).
- **Subscription pools** — Share model subscriptions within their permitted scope and meter each person's usage. [Learn more](admin/accounts.md).
- **Credential proxy** — Authorize model requests and select an eligible subscription without giving its key to a session. [Learn more](security.md).
- **Provisioning** — Create and recycle managed nodes for people. [Learn more](admin/machines.md).
- **Status and telemetry** — Collect health signals and explain service state. The [public status page](/status) is available without signing in. [Learn more](member/health.md).

### 3 · Data

- **Database** — Central accounts, session records, usage and settings; a session record is not the running process. [Learn more](self-host/install.md).
- **Secrets vault** — Central protected storage for subscription and provider credentials. [Learn more](security.md).
- **Release store** — Published releases that nodes verify before applying. [Learn more](security.md).
- **Backups** — Recovery copies of central state; operators manage recovery separately from running sessions. [Learn more](self-host/install.md).

Nodes initiate an encrypted connection to the hub; they do not access the data layer directly.

### 4 · Infrastructure · nodes that run sessions

- **Managed macOS nodes** — Managed hosts with a separate account for each person. [Learn more](security.md).
- **Managed Linux nodes** — Managed container environments for sessions. [Learn more](admin/machines.md).
- **Personal nodes** — A person's own machine joined to the fleet. [Learn more](self-host/quickstart.md).
- **Node agent** — Runs on a node, maintains its outward connection, manages sessions and applies updates. [Learn more](self-host/install.md).

<!-- blueprint:external -->
## External services

- **Model providers** — Answer model requests forwarded by the credential proxy. [Learn more](admin/accounts.md).
- **Identity providers** — Supply sign-in identities; the hub decides access. [Learn more](admin/access.md).
- **Source and CI** — Host code, test changes and produce releases. [Learn more](self-host/install.md).

<!-- blueprint:cross -->
## Cross-cutting concerns

- **Observability** — Connection health, session experience and service status. [Learn more](member/health.md).
- **Security** — Least privilege, protected credentials and verified releases. [Learn more](security.md).
- **Delivery** — Tested changes and recoverable releases, with staged connection handover and automatic reconnection of browser streams. [Learn more](self-host/install.md).

<!-- blueprint:flows -->
## How requests flow

These paths describe the responsibilities behind live browser access, model requests, node state updates and release handover.

### Chatting with an agent

1. The browser opens the portal.
2. The hub authenticates the person and finds their session.
3. The hub relays the conversation to the node running it.
4. Replies stream back through the hub to the browser.

### An agent calls a model

1. The agent on a node sends a model request to the credential proxy.
2. The proxy authorizes it, chooses an eligible subscription from the pool and meters usage.
3. The provider receives the request; its response returns through the proxy to the session.

### A node stays connected

1. The node agent initiates an encrypted outward connection to the hub.
2. The hub delivers work and settings through that connection.
3. The node pushes state changes to the hub; older nodes switch as they update.

### A release ships

1. A change passes automated checks and merges.
2. The release process publishes a verified release and deploys the hub.
3. Nodes verify and apply their releases. Connections are handed over in stages during deployment, and browser streams reconnect automatically.

<!-- blueprint:boundaries -->
## Trust boundaries and data

- **At the hub:** the database holds central records; the secrets vault holds model credentials. The credential proxy uses those credentials when forwarding authorized requests.
- **On a node:** the session process, working tree and local files live where the agent runs. A managed node is operated by the service; a personal node remains under its owner's control.
- **Across the node/hub boundary:** session messages and output, task and session state, settings and health signals travel through the hub's authorized channels. Browser access relays conversation content through the hub; local files are not automatically a central database backup.
- **Across the provider boundary:** model requests leave the node through the credential proxy. Prompts, conversation context and any code or tool output included by the agent can reach the model provider. Central keys do not make that content stay on the node.
- **Never into a session:** subscription and provider model keys stay in the central vault and proxy. A session can hold a scoped access credential; that is not the underlying model key.

For isolation, credential lifetimes, revocation and compromise boundaries, read [Security and isolation](security.md). Repository credentials and external tool integrations have their own access boundaries; the model-key rule does not describe every secret a person may give an agent.

<!-- blueprint:principles -->
## Design principles and why

### Native agents, unmodified · live

Sessions run the official Claude Code and Codex CLIs directly and follow upstream updates, without wrapping them in a proprietary agent. Keeping the native agents intact lets people use the capabilities and workflows their model providers deliver, while Tokenman manages the runtime around them. [Using a session](member/usage.md) describes the experience; there is no public deep-dive on upstream CLI updates yet.

### Anytime, anywhere · live

Sessions stay on managed nodes and continue when a laptop closes. Browser, terminal and phone access let people return to the same running work from whichever device is available. Separating a session's lifetime from its client connection makes ongoing work independent of a person's device. [Connecting to sessions](member/connect.md) describes access from each device.

### One portal · live

Browser access converges on tokenman.io, with regional routing handled by the service and an accelerated entry for mainland China. This gives people one familiar path from sign-in to their sessions without choosing an entry point themselves. Existing access through WeChat and native clients remains available. [Member quickstart](member/quickstart.md) describes the session journey.

### Nodes dial out · live

A node initiates the connection to the hub so the service can reach its sessions without requiring an inbound application port on that node. This supports both managed environments and personal machines behind ordinary network boundaries. [Self-host setup](self-host/install.md) and [Security and isolation](security.md) describe the operating and trust model.

### Push, not poll · live

Nodes push state when it changes, avoiding repeated reads of unchanged state and keeping the hub's view fresh. Older nodes switch as they update. This reduces unnecessary requests while making changes visible promptly. [Node updates](self-host/install.md) covers update operations; [Service health](member/health.md) explains the health information available to readers.

### Keys stay central · live

Keeping model keys out of sessions limits what an agent or a compromised working environment can take. The proxy can enforce access, select subscriptions and revoke access centrally while the session uses a scoped credential. [Security and isolation](security.md) explains the boundary; [Subscription accounts](admin/accounts.md) describes administration.

### Uneventful deploys · live

Deployments hand connections over in stages, and browser streams reconnect automatically. This preserves continuity for ongoing work and reduces interruptions during routine releases. [Install and deploy](self-host/install.md) covers operation; [Release verification](security.md) explains how published releases are trusted.

### Visible health · live

The [public status page](/status) shows service health and incidents without requiring sign-in. Readable health information helps people distinguish a local connection problem from a service disruption. [Service health](member/health.md) explains the indicators and their limits, along with the additional details available after signing in.

<!-- blueprint:glossary -->
## Glossary

- **Hub** — The runtime control plane: it owns identity, task and session records, access decisions and subscription coordination.
- **Node** — A machine or execution environment that runs sessions. A **managed node** is operated by the service; a **personal node** is brought and controlled by its owner.
- **Session** — One run of a native agent process on a node, with its conversation reachable from supported clients.
- **Subscription pool** — A set of eligible model subscriptions shared under platform, organization or personal access rules.
- **Credential proxy** — The boundary that authorizes and forwards model requests with central model credentials, and meters their usage.
- **Node agent** — The node-side service that connects to the hub, manages local sessions and carries state and updates.

<!-- blueprint:version -->
Blueprint v4 · Updated 2026-10-26. Status labels describe this version, not a delivery date.

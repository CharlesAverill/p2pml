# p2pml - CS 6378

Distributed filesharing protocol in pure OCaml.

All code was written without the assistance of LLMs.

## Design Part I

[main.ml](bin/main.ml) is each node's entrypoint.
It reads the adjacency matrix file path from a command-line argument, opens and 
parses the file, and validates it (see `Part 1 Step 2`).
Validation occurs via a breadth-first search starting from the smallest 
node. If all nodes are visited, the graph is valid.

[node.ml](lib/node.ml) encodes the data structure that each node
maintains, including information about its host machine and the
network topology (see `Part 1 Step 3`).

[main.ml](bin/main.ml) continues to set up the peer-to-peer network
(see `Part 1 Step 4`). It first creates a server thread to always listen
for requests (see [server.ml](bin/server.ml)). In the main thread, it
iterates through the row of the adjacency matrix that corresponds to the
current node. For each non-zero value, it initiates a connection with the
corresponding node. These connections are made in threads, parallelizing the
network construction step.

Upon having received machine information from all adjacent nodes, the server 
thread is re-joined into the main thread.

## Design Part II
 
On startup, [node.ml](lib/node.ml) populates the node's `root` field with a
per-node directory `./stores/<id>` and its `files` list by reading all files
present in that directory (see `Part 2 Step 3`).
 
[main.ml](bin/main.ml) enters an interactive loop prompting the user for a
filename. If the file is already present in the node's `files` list (checked
via `local_search` in [node.ml](lib/node.ml)), it is available locally and no
network activity is required.
 
Otherwise, [main.ml](bin/main.ml) calls `search` in [search.ml](lib/search.ml),
which issues a `Search` message carrying a unique UUID, the filename, and the
current hop-count, initially set to 1 (see `Part 2 Step 1`). The search is
flooded to all adjacent neighbours via `flood_search`. A timer equal to the
hop-count in seconds is started.
 
[search.ml](lib/search.ml) maintains a `seen_table` that maps each search UUID
to the socket it was first received from. When [server.ml](bin/server.ml)
receives a `Search` message, `handle_search_message` checks the `seen_table`
to determine whether this UUID has been seen before (see `Part 2 Step 2`).
Duplicate requests are silently dropped. For the first occurrence, if the
searched file is present in the node's `files` list, a `SearchResult` message
carrying the UUID, filename, and local hostname is sent back to the socket the
request arrived from (see `Part 2 Step 3`). If the file is not present and the
hop-count is greater than zero, the request is forwarded to all adjacent
neighbours except the one it arrived from, with the hop-count decremented.
 
When a `SearchResult` message arrives at an intermediate node,
`handle_search_message` looks up the UUID in the `seen_table` to find the
socket the original request arrived from and forwards the reply upstream
(see `Part 2 Step 5`). When the result reaches the initiating node, the UUID
has no upstream socket entry, so the result is stored in the `results_table`
(see `Part 2 Step 4`).
 
The initiating node polls all peer sockets using `Unix.select` until the timer
expires, accumulating all `SearchResult` replies received within that window.
Replies received after the timer expires are ignored (see `Part 2 Step 6`).
The collected results are displayed as a numbered list of `(filename, hostname)`
tuples, and the user is prompted to select one (see `Part 2 Step 7`).
 
[main.ml](bin/main.ml) then calls `download_file` in [search.ml](lib/search.ml),
which opens a fresh direct TCP stream socket connection to the chosen host,
sends a `Download` message, and reads the response in chunks until the
connection closes. On success the file is written to the local store directory
and its path is appended to `self.files`, making it available for future
sharing. The direct connection is then closed (see `Part 2 Step 8`).
 
If the timer expires with no replies, the hop-count is doubled and the entire
process is repeated. This continues until at least one reply is received or the
hop-count exceeds 16, at which point a "File not found" error is logged
(see `Part 2 Step 9`). State in the `seen_table` and `results_table` for a
completed search is removed immediately after the timer expires, ensuring
stale search state is not retained.

## Design Part III
 
A node wishing to join an existing network passes a known node's hostname via
the `--join` command-line argument. In [main.ml](bin/main.ml), this causes
`init` to take the join path: it constructs the node, opens a stream socket
to the known node, and sends an `AugmentAdj` message carrying its own UUID
(see `Part 3 Step 2`). It then blocks on `recv_message` waiting for a
`WelcomeAdj` reply containing the current global adjacency matrix. Once
received, `init` continues as normal: it reads the relevant row of the new
adjacency matrix to determine its neighbours, and connects to them concurrently
in threads.
 
When [server.ml](bin/server.ml) receives an `AugmentAdj` message, it updates
the shared adjacency matrix by expanding it via `pad_adj` if necessary and
setting the bidirectional link between the joining node and itself. It sends a
`WelcomeAdj` reply directly to the joining node, then floods `WelcomeAdj` to
all current outbound connections so the rest of the network learns of the
topology change.
 
When a node receives a `WelcomeAdj` message, it compares the received matrix
to its own. If they differ, it updates its local copy and re-floods the
`WelcomeAdj` to its own outbound connections, propagating the change through
the network regardless of topology. If they are identical the message is
silently dropped, preventing broadcast storms.
 
A node departs by typing `!exit` at the prompt. [main.ml](bin/main.ml) sets
`kill_server_thread` to true and connects to its own server port to unblock
`Unix.accept`. The server thread, upon returning from `accept`, checks
`kill_server_thread` and rather than recursing, sends a `LeaveNetwork` message
carrying its UUID to each outbound neighbour, then sets `server_alive` to false
(see `Part 3 Step 3`).
The blocking `accept` only occurs after all other operations, such as downloads,
have terminated.
 
When [server.ml](bin/server.ml) receives a `LeaveNetwork` message, it zeroes
the departing node's row and column in the shared adjacency matrix and removes
the corresponding entry from `peer_fds` (see `Part 3 Step 4`). It then sets
`keep := false` to close the connection, which unblocks the departing node's
send-side wait and allows it to exit cleanly.

## Building

Clone to CS servers `dcXX.utdallas.edu` - these have OCaml and Dune pre-installed.

```
git clone https://github.com/CharlesAVerill/p2pml && cd p2pml
dune build
```

## Running

On each desired machine, run

```
dune exec -- p2pml ./example_adj.txt
```

[example_adj.txt](./example_adj.txt) contains:

```
010
101
111
```

So dc01 <-> dc02, dc02 <-> dc03, dc03 -> dc01.

## Part I Log

Running the startup command on each machine prints out the machine info (e.g. hostname)
from each connected machine:

### DC01
```
{dc01:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt 
LOG:[INFO] - Adjacency matrix represents connected graph
===Connection Information===
==Node==
Network size: 3
UUID: 2
Root: ./
Files: []
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu
```

### DC02
```
{dc02:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
===Connection Information===
==Node==
Network size: 3
UUID: 1
Root: ./
Files: []
Connections: 
=Machine Info=
Hostname: dc01.utdallas.edu
==Node==
Network size: 3
UUID: 3
Root: ./
Files: []
Connections: 
=Machine Info=
Hostname: dc03.utdallas.edu
```

### DC03
```
{dc03:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
===Connection Information===
==Node==
Network size: 3
UUID: 1
Root: ./
Files: []
Connections: 
=Machine Info=
Hostname: dc01.utdallas.edu
==Node==
Network size: 3
UUID: 2
Root: ./
Files: []
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu
```

## Part II Log

Running the startup command on each machine prints the same machine info as
before, now showing files in the local store.
After this, it prompts the user to request a file from the network.
Upon submitting a file path, the client searches the network for the file,
retrieves all possible download options, and then prints them out.
The user selects an option to download.

### DC01
```
{dc01:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
===Connection Information===
==Node==
Network size: 3
UUID: 2
Root: ./stores/02
Files: [./stores/02/hello02.txt]
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu
LOG:[INFO] - Received MachineInfo request

>> Request file: ./stores/03/hello03.txt
LOG:[INFO] - Received MachineInfo request
LOG:[INFO] - Searching for './stores/03/hello03.txt' with hop-count=1 (timeout=1s)
LOG:[INFO] - No replies for './stores/03/hello03.txt' at hop-count=1; doubling.
LOG:[INFO] - Searching for './stores/03/hello03.txt' with hop-count=2 (timeout=2s)
LOG:[INFO] - Received SearchResult (295261110, ./stores/03/hello03.txt, dc03.utdallas.edu)
LOG:[INFO] - SearchResult for './stores/03/hello03.txt' reached initiator (from dc03.utdallas.edu)

Search results:
  0) ./stores/03/hello03.txt @ dc03.utdallas.edu

>> Select index to download from (0-0): 0
LOG:[INFO] - Downloaded './stores/03/hello03.txt' -> './stores/01/hello03.txt'
LOG:[INFO] - Saved to './stores/01/hello03.txt'. File added to share list.
```

### DC02
```
{dc02:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
LOG:[INFO] - Received MachineInfo request
LOG:[INFO] - Received MachineInfo request
===Connection Information===
==Node==
Network size: 3
UUID: 3
Root: ./stores/03
Files: [./stores/03/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc03.utdallas.edu
==Node==
Network size: 3
UUID: 1
Root: ./stores/01
Files: [./stores/01/hello01.txt]
Connections: 
=Machine Info=
Hostname: dc01.utdallas.edu

>> Request file:
LOG:[INFO] - Received Search request (70360265, ./stores/03/hello03.txt, 0)
LOG:[INFO] - Received Search request (70360265, ./stores/03/hello03.txt, 0)
LOG:[INFO] - Received Search request (295261110, ./stores/03/hello03.txt, 1)
LOG:[INFO] - Received Search request (295261110, ./stores/03/hello03.txt, 1)
LOG:[INFO] - Received SearchResult (295261110, ./stores/03/hello03.txt, dc03.utdallas.edu)
LOG:[INFO] - Forwarding SearchResult for './stores/03/hello03.txt' upstream to 10.182.157.
```

### DC03
```
{dc03:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
===Connection Information===
==Node==
Network size: 3
UUID: 2
Root: ./stores/02
Files: [./stores/02/hello02.txt]
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu
==Node==
Network size: 3
UUID: 1
Root: ./stores/01
Files: [./stores/01/hello01.txt]
Connections: 
=Machine Info=
Hostname: dc01.utdallas.edu
LOG:[INFO] - Received MachineInfo request

>> Request file:
LOG:[INFO] - Received Search request (295261110, ./stores/03/hello03.txt, 0)
LOG:[INFO] - Received Search request (295261110, ./stores/03/hello03.txt, 0)
LOG:[INFO] - Found './stores/03/hello03.txt', sending SearchResult to 10.182.157.5
LOG:[INFO] - Received Download request (./stores/03/hello03.txt)
```

## Part III Log

Clients 2 and 3 are booted via the provided adjacency matrix, while client 1 waits
for a connection to client 2 via the `--join` command line option.
Once the network is created according to the adjacency matrix, each node prints out
the machine info of its connected nodes, as usual.

Client 3 then leaves the network, broadcasting to client 2, which broadcasts the
matrix change to client 1.
Client 3 then re-joins via a direct connection to client 2 (similarly to how client
1 joined), and then indirectly finds a file at client 1 through client 2, and downloads
it.
Finally, nodes 3, 2, and then 1 leave the network.


### DC01

```
{dc01:~/6378/p2pml} dune exec -- p2pml --join dc02.utdallas.edu
LOG:[DEBUG] - Sending message: AUGMENTADJ:1
===Connection Information===
LOG:[DEBUG] - Sending message: MACHINE_INFO
==Node==
Network size: 3
UUID: 2
Root: ./stores/02
Files: [./stores/02/hello02.txt, ./stores/02/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu

>> LOG:[INFO] - Received MachineInfo request
LOG:[INFO] - Received MachineInfo request


>> !adj
010
101
111

>> LOG:[INFO] - Node 3 is leaving the network


>> LOG:[INFO] - Received topology update
LOG:[INFO] - Broadcasting topology update
LOG:[DEBUG] - Sending message: WELCOME:010|101|010


>> !adj
010
101
010

>> LOG:[INFO] - Received Search request (665276122, ./stores/01/hello01.txt, 0)
LOG:[INFO] - Found './stores/01/hello01.txt', sending SearchResult to 10.182.157.5
LOG:[DEBUG] - Sending message: SEARCHRES:665276122:dc01.utdallas.edu:./stores/01/hello01.txt
LOG:[INFO] - Received Search request (665276122, ./stores/01/hello01.txt, 0)
LOG:[INFO] - Received Search request (665276122, ./stores/01/hello01.txt, 0)
LOG:[INFO] - Received Download request (./stores/01/hello01.txt)
LOG:[DEBUG] - Sending message: DOWNLOADDATA:23:./stores/01/hello01.txt
LOG:[INFO] - Node 2 is leaving the network


>> !exit
LOG:[CRITICAL] - Leaving the network upon user request
LOG:[DEBUG] - Sending message: LEAVENET:1
```

### DC02

```
{dc02:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
LOG:[INFO] - Node 1 is joining the network
LOG:[DEBUG] - Sending message: WELCOME:010|101|111
LOG:[DEBUG] - Sending message: WELCOME:010|101|111
LOG:[INFO] - Received MachineInfo request
===Connection Information===
LOG:[DEBUG] - Sending message: MACHINE_INFO
==Node==
Network size: 0
UUID: 1
Root: ./stores/01
Files: [./stores/01/hello01.txt, ./stores/01/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc01.utdallas.edu
LOG:[DEBUG] - Sending message: MACHINE_INFO
==Node==
Network size: 3
UUID: 3
Root: ./stores/03
Files: [./stores/03/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc03.utdallas.edu

>> LOG:[INFO] - Received MachineInfo request


>> LOG:[INFO] - Node 3 is leaving the network


>> LOG:[INFO] - Node 3 is joining the network
LOG:[DEBUG] - Sending message: WELCOME:010|101|010
LOG:[DEBUG] - Sending message: WELCOME:010|101|010
LOG:[DEBUG] - Sending message: WELCOME:010|101|010
LOG:[INFO] - Received topology update
LOG:[INFO] - Received MachineInfo request


>> LOG:[INFO] - Received Search request (646112005, ./stores/01/hello01.txt, 0)
LOG:[INFO] - Received Search request (665276122, ./stores/01/hello01.txt, 1)
LOG:[DEBUG] - Sending message: SEARCH:665276122:0:./stores/01/hello01.txt
LOG:[DEBUG] - Sending message: SEARCH:665276122:0:./stores/01/hello01.txt
LOG:[DEBUG] - Sending message: SEARCH:665276122:0:./stores/01/hello01.txt
LOG:[INFO] - Received SearchResult (665276122, ./stores/01/hello01.txt, dc01.utdallas.edu)
LOG:[INFO] - Forwarding SearchResult for './stores/01/hello01.txt' upstream to 10.182.157.6
LOG:[DEBUG] - Sending message: SEARCHRES:665276122:dc01.utdallas.edu:./stores/01/hello01.txt
LOG:[INFO] - Node 3 is leaving the network


>> !exit
LOG:[CRITICAL] - Leaving the network upon user request
LOG:[DEBUG] - Sending message: LEAVENET:2
LOG:[DEBUG] - Sending message: LEAVENET:2
{dc02:~/6378/p2pml} 
```

### DC03

```
{dc03:~/6378/p2pml} dune exec -- p2pml ./example_adj.txt
LOG:[INFO] - Adjacency matrix represents connected graph
LOG:[INFO] - Received topology update
LOG:[INFO] - Received MachineInfo request
===Connection Information===
LOG:[DEBUG] - Sending message: MACHINE_INFO
==Node==
Network size: 0
UUID: 1
Root: ./stores/01
Files: [./stores/01/hello01.txt, ./stores/01/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc01.utdallas.edu
LOG:[DEBUG] - Sending message: MACHINE_INFO
==Node==
Network size: 3
UUID: 2
Root: ./stores/02
Files: [./stores/02/hello02.txt, ./stores/02/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu

>> 

>> !exit
LOG:[CRITICAL] - Leaving the network upon user request
LOG:[DEBUG] - Sending message: LEAVENET:3
LOG:[DEBUG] - Sending message: LEAVENET:3
{dc03:~/6378/p2pml} dune exec -- p2pml --join dc02.utdallas.edu
LOG:[DEBUG] - Sending message: AUGMENTADJ:3
===Connection Information===
LOG:[DEBUG] - Sending message: MACHINE_INFO
==Node==
Network size: 3
UUID: 2
Root: ./stores/02
Files: [./stores/02/hello02.txt, ./stores/02/hello03.txt]
Connections: 
=Machine Info=
Hostname: dc02.utdallas.edu

>> ./stores/01/hello01.txt
LOG:[INFO] - Searching for './stores/01/hello01.txt' with hop-count=1 (timeout=1s)
LOG:[DEBUG] - Sending message: SEARCH:646112005:0:./stores/01/hello01.txt
LOG:[INFO] - No replies for './stores/01/hello01.txt' at hop-count=1; doubling.
LOG:[INFO] - Searching for './stores/01/hello01.txt' with hop-count=2 (timeout=2s)
LOG:[DEBUG] - Sending message: SEARCH:665276122:1:./stores/01/hello01.txt
LOG:[INFO] - Received SearchResult (665276122, ./stores/01/hello01.txt, dc01.utdallas.edu)
LOG:[INFO] - SearchResult for './stores/01/hello01.txt' reached initiator (from dc01.utdallas.edu)

Search results:
  0) ./stores/01/hello01.txt @ dc01.utdallas.edu

>> Select index to download from (0-0): 0
LOG:[DEBUG] - Downloading './stores/01/hello01.txt' from dc01.utdallas.edun
LOG:[DEBUG] - Sending message: DOWNLOAD:./stores/01/hello01.txt
LOG:[INFO] - Downloaded './stores/01/hello01.txt' -> './stores/03/hello01.txt'
LOG:[INFO] - Saved to './stores/03/hello01.txt'. File added to share list.


>> !exit
LOG:[CRITICAL] - Leaving the network upon user request
LOG:[DEBUG] - Sending message: LEAVENET:3
{dc03:~/6378/p2pml} 
```

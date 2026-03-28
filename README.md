# p2pml - CS 6378

Distributed filesharing protocol in pure OCaml.

All code was written without the assistance of LLMs.

## Design

[main.ml](bin/main.ml) is each node's entrypoint.
It reads the adjacency matrix file path from a command-line argument, opens and parses the file, and validates it (see `Part 1 Step 2`).
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

Upon having received machine information from all adjacent nodes, the server thread is re-joined into the main thread.

## Building

Clone to CS servers `dcXX.utdallas.edu` - these have OCaml and Dune built-in

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

So dc01 <-> dc02, dc02 <-> dc0{1,3}.

Running the above command on each machine prints out the machine info (e.g. hostname)
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

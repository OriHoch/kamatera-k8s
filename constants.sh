# refer to kamatera_server_options.json for the available values

# default settings for all nodes
DEFAULT_DATACENTER=EU
DEFAULT_BILLING=hourly

# master node
DEFAULT_MASTER_NODE_CPU=2B
DEFAULT_MASTER_NODE_RAM=2048
DEFAULT_MASTER_NODE_DISK_SIZE_GB=30

# worker node
DEFAULT_WORKER_NODE_CPU=2B
DEFAULT_WORKER_NODE_RAM=2048
DEFAULT_WORKER_NODE_DISK_SIZE_GB=30

# load balancer node
DEFAULT_LOAD_BALANCER_NODE_CPU=2B
DEFAULT_LOAD_BALANCER_NODE_RAM=2048
DEFAULT_LOAD_BALANCER_NODE_DISK_SIZE_GB=30

# uncomment to skip creation of optional components
# DEFAULT_CLUSTER_SKIP_WORKER_NODE=yes
# DEFAULT_CLUSTER_SKIP_STORAGE=yes
# DEFAULT_CLUSTER_SKIP_LOAD_BALANCER=yes

# skip some additional steps (not recommended)
# DEFAULT_CLUSTER_SKIP_HELM=yes
# DEFAULT_CLUSTER_SKIP_ROOT_CHART=yes

# default OS for all cluster nodes
DEFAULT_DISK_DESCRIPTION=ubuntu_server_18.04_64-bit

# uncomment to allow scheduling workloads on the master node
# DEFAULT_MASTER_ALLOW_SCHEDULING=yes

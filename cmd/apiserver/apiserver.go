/*
Copyright 2014 Google Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// apiserver is the main api server and master for the cluster.
// it is responsible for serving the cluster management API.
package main

import (
	"flag"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/GoogleCloudPlatform/kubernetes/pkg/api"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/apiserver"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/auth/authenticator/bearertoken"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/auth/authenticator/tokenfile"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/auth/handlers"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/capabilities"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/client"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/cloudprovider"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/master"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/resources"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/tools"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/ui"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/util"
	"github.com/GoogleCloudPlatform/kubernetes/pkg/version/verflag"

	"github.com/coreos/go-etcd/etcd"
	"github.com/golang/glog"
)

var (
	port                  = flag.Uint("port", 8080, "The port to listen on. Default 8080")
	address               = util.IP(net.ParseIP("127.0.0.1"))
	apiPrefix             = flag.String("api_prefix", "/api", "The prefix for API requests on the server. Default '/api'")
	storageVersion        = flag.String("storage_version", "", "The version to store resources with. Defaults to server preferred")
	cloudProvider         = flag.String("cloud_provider", "", "The provider for cloud services.  Empty string for no provider.")
	cloudConfigFile       = flag.String("cloud_config", "", "The path to the cloud provider configuration file.  Empty string for no configuration file.")
	minionRegexp          = flag.String("minion_regexp", "", "If non empty, and -cloud_provider is specified, a regular expression for matching minion VMs")
	minionPort            = flag.Uint("minion_port", 10250, "The port at which kubelet will be listening on the minions.")
	healthCheckMinions    = flag.Bool("health_check_minions", true, "If true, health check minions and filter unhealthy ones. Default true")
	minionCacheTTL        = flag.Duration("minion_cache_ttl", 30*time.Second, "Duration of time to cache minion information. Default 30 seconds")
	tokenAuthFile         = flag.String("token_auth_file", "", "If set, the file that will be used to secure the API server via token authentication")
	etcdServerList        util.StringList
	etcdConfigFile        = flag.String("etcd_config", "", "The config file for the etcd client. Mutually exclusive with -etcd_servers")
	machineList           util.StringList
	corsAllowedOriginList util.StringList
	allowPrivileged       = flag.Bool("allow_privileged", false, "If true, allow privileged containers.")
	// TODO: Discover these by pinging the host machines, and rip out these flags.
	nodeMilliCPU = flag.Int("node_milli_cpu", 1000, "The amount of MilliCPU provisioned on each node")
	nodeMemory   = flag.Int("node_memory", 3*1024*1024*1024, "The amount of memory (in bytes) provisioned on each node")
)

func init() {
	flag.Var(&address, "address", "The IP address on to serve on (set to 0.0.0.0 for all interfaces)")
	flag.Var(&etcdServerList, "etcd_servers", "List of etcd servers to watch (http://ip:port), comma separated. Mutually exclusive with -etcd_config")
	flag.Var(&machineList, "machines", "List of machines to schedule onto, comma separated.")
	flag.Var(&corsAllowedOriginList, "cors_allowed_origins", "List of allowed origins for CORS, comma separated.  An allowed origin can be a regular expression to support subdomain matching.  If this list is empty CORS will not be enabled.")
}

func verifyMinionFlags() {
	if *cloudProvider == "" || *minionRegexp == "" {
		if len(machineList) == 0 {
			glog.Info("No machines specified!")
		}
		return
	}
	if len(machineList) != 0 {
		glog.Info("-machines is overwritten by -minion_regexp")
	}
}

func initCloudProvider(name string, configFilePath string) cloudprovider.Interface {
	var config *os.File

	if name == "" {
		glog.Info("No cloud provider specified.")
		return nil
	}

	if configFilePath != "" {
		var err error

		config, err = os.Open(configFilePath)
		if err != nil {
			glog.Fatalf("Couldn't open cloud provider configuration %s: %#v",
				configFilePath, err)
		}

		defer config.Close()
	}

	cloud, err := cloudprovider.GetCloudProvider(name, config)
	if err != nil {
		glog.Fatalf("Couldn't init cloud provider %q: %#v", name, err)
	}
	if cloud == nil {
		glog.Fatalf("Unknown cloud provider: %s", name)
	}

	return cloud
}

func newEtcd(etcdConfigFile string, etcdServerList util.StringList) (helper tools.EtcdHelper, err error) {
	var client tools.EtcdGetSet
	if etcdConfigFile != "" {
		client, err = etcd.NewClientFromFile(etcdConfigFile)
		if err != nil {
			return helper, err
		}
	} else {
		client = etcd.NewClient(etcdServerList)
	}

	return master.NewEtcdHelper(client, *storageVersion)
}

func main() {
	flag.Parse()
	util.InitLogs()
	defer util.FlushLogs()

	verflag.PrintAndExitIfRequested()
	verifyMinionFlags()

	if (*etcdConfigFile != "" && len(etcdServerList) != 0) || (*etcdConfigFile == "" && len(etcdServerList) == 0) {
		glog.Fatalf("specify either -etcd_servers or -etcd_config")
	}

	capabilities.Initialize(capabilities.Capabilities{
		AllowPrivileged: *allowPrivileged,
	})

	cloud := initCloudProvider(*cloudProvider, *cloudConfigFile)

	podInfoGetter := &client.HTTPPodInfoGetter{
		Client: http.DefaultClient,
		Port:   *minionPort,
	}

	// TODO: expose same flags as client.BindClientConfigFlags but for a server
	clientConfig := &client.Config{
		Host:    net.JoinHostPort(address.String(), strconv.Itoa(int(*port))),
		Version: *storageVersion,
	}
	client, err := client.New(clientConfig)
	if err != nil {
		glog.Fatalf("Invalid server address: %v", err)
	}

	helper, err := newEtcd(*etcdConfigFile, etcdServerList)
	if err != nil {
		glog.Fatalf("Invalid storage version or misconfigured etcd: %v", err)
	}

	m := master.New(&master.Config{
		Client:             client,
		Cloud:              cloud,
		EtcdHelper:         helper,
		HealthCheckMinions: *healthCheckMinions,
		Minions:            machineList,
		MinionCacheTTL:     *minionCacheTTL,
		MinionRegexp:       *minionRegexp,
		PodInfoGetter:      podInfoGetter,
		NodeResources: api.NodeResources{
			Capacity: api.ResourceList{
				resources.CPU:    util.NewIntOrStringFromInt(*nodeMilliCPU),
				resources.Memory: util.NewIntOrStringFromInt(*nodeMemory),
			},
		},
	})

	mux := http.NewServeMux()
	apiserver.NewAPIGroup(m.API_v1beta1()).InstallREST(mux, *apiPrefix+"/v1beta1")
	apiserver.NewAPIGroup(m.API_v1beta2()).InstallREST(mux, *apiPrefix+"/v1beta2")
	apiserver.InstallSupport(mux)
	ui.InstallSupport(mux)

	handler := http.Handler(mux)

	if len(corsAllowedOriginList) > 0 {
		allowedOriginRegexps, err := util.CompileRegexps(corsAllowedOriginList)
		if err != nil {
			glog.Fatalf("Invalid CORS allowed origin, --cors_allowed_origins flag was set to %v - %v", strings.Join(corsAllowedOriginList, ","), err)
		}
		handler = apiserver.CORS(handler, allowedOriginRegexps, nil, nil, "true")
	}

	if len(*tokenAuthFile) != 0 {
		auth, err := tokenfile.New(*tokenAuthFile)
		if err != nil {
			glog.Fatalf("Unable to load the token authentication file '%s': %v", *tokenAuthFile, err)
		}
		userContexts := handlers.NewUserRequestContext()
		handler = handlers.NewRequestAuthenticator(userContexts, bearertoken.New(auth), handlers.Unauthorized, handler)
	}

	handler = apiserver.RecoverPanics(handler)

	s := &http.Server{
		Addr:           net.JoinHostPort(address.String(), strconv.Itoa(int(*port))),
		Handler:        handler,
		ReadTimeout:    5 * time.Minute,
		WriteTimeout:   5 * time.Minute,
		MaxHeaderBytes: 1 << 20,
	}
	glog.Fatal(s.ListenAndServe())
}

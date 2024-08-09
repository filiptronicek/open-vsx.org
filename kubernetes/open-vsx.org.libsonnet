local utils = import "utils.libsonnet";

local labels(env) = {
  app: env.appName,
  environment: env.envName,
};

local namespacedResourceMetadata(env) = {
  name: "%s-%s" % [ env.appName, env.envName, ],
  namespace: env.namespace,
  labels: labels(env),
};

local newEnvironment(envName) = {
  envName: envName,
  appName: "open-vsx-org",
  namespace: self.appName,
  host: if envName == "staging" then "staging.open-vsx.org" else "open-vsx.org",

  elasticsearch: {
    local thisES = self,
    name: "elasticsearch-%s" % envName,
    httpCerts: {
      # This secret is generated by the ELK operator. We control the naming scheme
      # via the name of the ES instance.
      secretName: "%s-es-http-certs-internal" % thisES.name,
      caFilename: "ca.crt"
    },
    truststore: {
      path: "/run/secrets/open-vsx.org/truststore",
      filename: "elasticsearch-http-certs.keystore",
      password: "changeit", # we don't care making this one public!
    }
  },

  deploymentConfig: {
    secretName: "deployment-configuration-%s" % envName,
    path: "/run/secrets/open-vsx.org/deployment",
    filename: "configuration.yml",
  },
};

local newGrafanaAgentConfigMap(env) = {
  apiVersion: "v1",
  kind: "ConfigMap",
  metadata: {
    name: "grafana-agent-configmap",
    namespace: env.namespace,
    labels: labels(env),
  },
  data: {
    "agent.yml": |||
      server:
        log_level: debug
      integrations:
        prometheus_remote_write:
        - basic_auth:
            password: ${PROMETHEUS_PASSWORD}
            username: ${PROMETHEUS_USERNAME}
          url: ${PROMETHEUS_URL}
        agent:
          enabled: true
          relabel_configs:
          - action: replace
            source_labels:
            - agent_hostname
            target_label: instance
          - action: replace
            target_label: job
            replacement: "integrations/agent-check"
          metric_relabel_configs:
          - action: keep
            regex: (prometheus_target_sync_length_seconds_sum|prometheus_target_scrapes_.*|prometheus_target_interval.*|prometheus_sd_discovered_targets|agent_build.*|agent_wal_samples_appended_total|process_start_time_seconds)
            source_labels:
            - __name__
      metrics:
        configs:
        - name: integrations
          remote_write:
          - basic_auth:
              password: ${PROMETHEUS_PASSWORD}
              username: ${PROMETHEUS_USERNAME}
            url: ${PROMETHEUS_URL}
          scrape_configs:
          - job_name: integrations/spring-boot
            static_configs:
              - targets: ['localhost:8081']
            metrics_path: /actuator/prometheus
            metric_relabel_configs:
            - source_labels: [exported_instance]
              target_label: instance
            - regex: "^(exported_instance|deployment_environment|service_instance_id|service_name)$"
              action: labeldrop
        global:
          scrape_interval: 60s
      traces:
        configs:
        - name: default
          remote_write:
          - endpoint: ${TEMPO_URL}
            basic_auth:
              username: ${TEMPO_USERNAME}
              password: ${TEMPO_PASSWORD}
          receivers:
            zipkin:
              endpoint: localhost:9411
              parse_string_tags: false
    |||
  }
};

local newDeployment(env, dockerImage) = {

  local elasticsearchCertsVolumeName = "elastic-internal-http-certificates",
  local truststoreWithESCertsVolumeName = "truststore-with-elasticsearch-certs",
  local deploymentConfigurationVolumeName = "deployment-configuration",

  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: namespacedResourceMetadata(env),
  spec: {
    replicas: if (env.envName == "staging") then 1 else 2,
    progressDeadlineSeconds: 3600,
    selector: {
      matchLabels: labels(env) + {
        type: "website"
      },
    },
    template: {
      metadata: {
        labels: labels(env) + {
          type: "website"
        }
      },
      spec: {
        local thisPod = self,
        initContainers: [
          {
            local thisContainer = self,
            name: "init-keystore",
            image: dockerImage,
            command: [
              "sh",
              "-c",
              "keytool -import -noprompt -alias es-http-certs-internal -file %s/%s -storetype jks -storepass '%s' -keystore %s/%s" % [
                thisContainer._volumeMounts[elasticsearchCertsVolumeName],
                env.elasticsearch.httpCerts.caFilename,
                env.elasticsearch.truststore.password,
                thisContainer._volumeMounts[truststoreWithESCertsVolumeName],
                env.elasticsearch.truststore.filename
              ],
            ],
            volumeMounts: utils.pairList(self._volumeMounts, vfield="mountPath"),
            _volumeMounts:: {
              [elasticsearchCertsVolumeName]: "/run/secrets/elasticsearch/http-certs",
              [truststoreWithESCertsVolumeName]: env.elasticsearch.truststore.path,
            },
          }
        ],
        containers: utils.namedObjectList(self._containers),
        _containers:: {
          "grafana-agent": {
            name: "grafana-agent",
            image: "docker.io/grafana/agent:v0.39.1",
            command: ["/bin/grafana-agent"],
            args: [
              "--config.file=$(CONFIG_FILE_PATH)",
              "--metrics.wal-directory=$(DATA_FILE_PATH)",
              "--config.expand-env=true"
            ],
            env: utils.pairList(self._env),
            _env:: {
              CONFIG_FILE_PATH: "/etc/grafana-agent/agent.yml",
              DATA_FILE_PATH: "/etc/grafana-agent/data",
              ENVNAME: env.envName
            },
            envFrom: [
              {
                secretRef: {
                  name: "grafana-cloud-secret-%s" % env.envName
                }
              }
            ],
            volumeMounts: utils.pairList(self._volumeMounts, vfield="mountPath"),
            _volumeMounts:: {
              "grafana-agent-config-volume": "/etc/grafana-agent",
              "grafana-agent-data-volume": "/etc/grafana-agent/data"
            }
          },
          [env.appName]: {
            local thisContainer = self,
            name: env.appName,
            image: dockerImage,
            env: utils.pairList(self._env),
            local jvmPerfOptions = " -XX:+AlwaysPreTouch -XX:+HeapDumpOnOutOfMemoryError -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC -XX:+UnlockExperimentalVMOptions -XX:+UnlockDiagnosticVMOptions -Dlog4j2.formatMsgNoLookups=true -Dlog4j.formatMsgNoLookups=true",
            _env:: {
              JVM_ARGS: (if (env.envName == "staging") then "-Dspring.datasource.hikari.maximum-pool-size=5 -Xms512M -Xmx1536M" else "-Xms4G -Xmx6G") + jvmPerfOptions,
              DEPLOYMENT_CONFIG: "%s/%s" % [ env.deploymentConfig.path, env.deploymentConfig.filename, ],
              ENVNAME: env.envName
            },
            envFrom: [
              {
                secretRef: {
                  name: "grafana-cloud-secret-%s" % env.envName
                }
              }
            ],
            ports: utils.pairList(self._ports, vfield="containerPort"),
            _ports:: {
              http: 8080,
              "http-management": 8081,
            },
            volumeMounts: utils.pairList(self._volumeMounts, vfield="mountPath"),
            _volumeMounts:: {
              [deploymentConfigurationVolumeName]: env.deploymentConfig.path,
              [truststoreWithESCertsVolumeName]: env.elasticsearch.truststore.path,
            },
            resources: if (env.envName == "staging") then {
              requests: {
                memory: "2Gi",
                cpu: "250m",
              },
              limits: {
                memory: "2Gi",
                cpu: "1000m",
              }
            } else {
              requests: {
                memory: "8Gi",
                cpu: "3000m",
              },
              limits: {
                memory: "8Gi",
                cpu: "5000m",
              }
            },
            livenessProbe: {
              httpGet: {
                path: "/actuator/health/liveness",
                port: "http-management"
              },
              failureThreshold: 3,
              periodSeconds: 10
            },
            readinessProbe: {
              httpGet: {
                path: "/actuator/health/readiness",
                port: "http-management"
              },
              failureThreshold: 2,
              periodSeconds: 10
            },
            startupProbe: {
              httpGet: {
                path: "/actuator/health/readiness",
                port: "http-management"
              },
              failureThreshold: 360,
              periodSeconds: 10
            }
          },
        },
        volumes: utils.namedObjectList(self._volumes),
        _volumes:: {
          "grafana-agent-config-volume": {
            configMap: {
              name: "grafana-agent-configmap",
              items: [
                {
                  key: "agent.yml",
                  path: "agent.yml"
                }
              ]
            }
          },
          "grafana-agent-data-volume": {
            emptyDir: {
              medium: "Memory"
            }
          },
          [deploymentConfigurationVolumeName]: {
            local thisVolume = self,
            secret: {
              defaultMode: 420,
              optional: false,
              secretName: env.deploymentConfig.secretName,
            }
          },
          [truststoreWithESCertsVolumeName]: {
            emptyDir: {
              medium: "Memory"
            }
          },
          [elasticsearchCertsVolumeName]: {
            secret: {
              defaultMode: 420,
              optional: false,
              secretName: env.elasticsearch.httpCerts.secretName,
            }
          },
        },
        affinity: {
          nodeAffinity: {
            preferredDuringSchedulingIgnoredDuringExecution: [
              {
                preference: {
                  matchExpressions: [
                    {
                      key: "speed",
                      operator: "NotIn",
                      values: [ "fast" ]
                    }
                  ]
                },
                weight: 1
              }
            ]
          }
        },
        topologySpreadConstraints: [
          {
            maxSkew: 1,
            topologyKey: "kubernetes.io/hostname",
            whenUnsatisfiable: "DoNotSchedule",
            labelSelector: {
              matchLabels: labels(env),
            },
          },
        ],
      }
    }
  }
};

local newService(env, deployment) = {
  apiVersion: "v1",
  kind: "Service",
  metadata: namespacedResourceMetadata(env),
  spec: {
    selector: labels(env) + {
      type: "website"
    },
    ports: utils.namedObjectList(self._ports),
    _ports:: {
      http: {
        port: 80,
        protocol: "TCP",
        targetPort: deployment.spec.template.spec._containers[env.appName]._ports["http"],
      },
    },
  },
};

local newRoute(env, service) = {
  apiVersion: "route.openshift.io/v1",
  kind: "Route",
  metadata: namespacedResourceMetadata(env) {
    annotations: {
      "haproxy.router.openshift.io/timeout": if (env.envName == "staging") then "30s" else "10m",
      "haproxy.router.openshift.io/disable_cookies": "true",
    },
  },
  spec: {
    host: env.host,
    path: "/",
    port: {
      targetPort: service.spec._ports["http"].targetPort,
    },
    tls: {
      insecureEdgeTerminationPolicy: "Redirect",
      termination: "edge"
    },
    to: {
      kind: "Service",
      name: service.metadata.name,
      weight: 100
    }
  }
};

local newElasticSearchCluster(env) = {
  apiVersion: "elasticsearch.k8s.elastic.co/v1",
  kind: "Elasticsearch",
  metadata: {
    name: env.elasticsearch.name,
    namespace: env.namespace,
    labels: labels(env),
  },
  spec: {
    version: "8.7.1",
    nodeSets: [
      {
        name: "default",
        volumeClaimTemplates: [
          {
            metadata: {
              name: "elasticsearch-data"
            },
            spec: {
              accessModes: [ "ReadWriteMany" ],
              resources: {
                requests: {
                  storage: "1Gi"
                }
              },
              storageClassName: "cephfs-2repl"
            }
          }
        ],
        config: {
          "node.roles": [ "master", "data" ],
          "node.store.allow_mmap": false
        },
        podTemplate: {
          metadata: {
            labels: labels(env),
          },
          spec: {
            containers: [
              {
                name: "elasticsearch",
                env: utils.pairList(self._env),
                _env:: {
                  ES_JAVA_OPTS: (if (env.envName == "staging") then "-Xms1g -Xmx1g" else "-Xms4g -Xmx4g") + " -Dlog4j2.formatMsgNoLookups=true",
                },
                resources: {
                  requests: {
                    memory: if (env.envName == "staging") then "2Gi" else "8Gi",
                    cpu: 1
                  },
                  limits: {
                    memory: if (env.envName == "staging") then "2Gi" else "8Gi",
                    cpu: if (env.envName == "staging") then 1 else 4,
                  }
                }
              }
            ],
            affinity: {
              nodeAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [
                  {
                    weight: 1,
                    preference: {
                      matchExpressions: [
                        {
                          key: "speed",
                          operator: "NotIn",
                          values: [ "fast", ],
                        },
                      ],
                    },
                  },
                ],
              },

              podAntiAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [
                  {
                    weight: 100,
                    podAffinityTerm: {
                      labelSelector: {
                        matchLabels: {
                          "elasticsearch.k8s.elastic.co/cluster-name": env.elasticsearch.name,
                        },
                      },
                      topologyKey: "kubernetes.io/hostname",
                    },
                  },
                ],
              },
            },
          },
        },
        count: if (env.envName == "staging") then 1 else 3,
      }
    ],
  }
};

local _newKubernetesResources(envName, image) = {
  local environment = newEnvironment(envName),
  local configMap = newGrafanaAgentConfigMap(environment),
  local deployment = newDeployment(environment, image),
  local service = newService(environment, deployment),

  arr: [
    configMap,
    deployment,
    service,
    newRoute(environment, service),
    newElasticSearchCluster(environment),
  ] + if envName == "production" then [ newRoute(environment, service) {
      metadata+: {
        name: "www-%s" % environment.appName
      },
      spec+: {
        host: "www.%s" % environment.host
      },
  }] else [],
};

local newKubernetesResources(envName, image) = _newKubernetesResources(envName, image).arr;

local newKubernetesYamlStream(envName, image) =
  std.manifestYamlStream(newKubernetesResources(envName, image), false, false);

{
  newEnvironment:: newEnvironment,
  newDeployment:: newDeployment,
  newService:: newService,
  newRoute:: newRoute,
  newElasticSearchCluster:: newElasticSearchCluster,

  newKubernetesResources:: newKubernetesResources,
  newKubernetesYamlStream:: newKubernetesYamlStream,
}

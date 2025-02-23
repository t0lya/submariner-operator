/*
SPDX-License-Identifier: Apache-2.0

Copyright Contributors to the Submariner project.

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

package submariner

import (
	"context"

	"github.com/go-logr/logr"
	"github.com/submariner-io/admiral/pkg/names"
	"github.com/submariner-io/submariner-operator/api/v1alpha1"
	"github.com/submariner-io/submariner-operator/internal/controllers/apply"
	"github.com/submariner-io/submariner-operator/internal/controllers/metrics"
	"github.com/submariner-io/submariner-operator/pkg/httpproxy"
	"github.com/submariner-io/submariner-operator/pkg/images"
	opnames "github.com/submariner-io/submariner-operator/pkg/names"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
)

//nolint:wrapcheck // No need to wrap errors here.
func (r *Reconciler) reconcileGlobalnetDaemonSet(ctx context.Context, instance *v1alpha1.Submariner, reqLogger logr.Logger,
) (*appsv1.DaemonSet, error) {
	daemonSet, err := apply.DaemonSet(ctx, instance, newGlobalnetDaemonSet(instance, names.GlobalnetComponent), reqLogger,
		r.config.ScopedClient, r.config.Scheme)
	if err != nil {
		return nil, err
	}

	err = metrics.Setup(ctx, r.config.ScopedClient, r.config.RestConfig, r.config.Scheme,
		&metrics.ServiceInfo{
			Name:            names.GlobalnetComponent,
			Namespace:       instance.Namespace,
			ApplicationKey:  "app",
			ApplicationName: names.MetricsProxyComponent,
			Owner:           instance,
			Port:            globalnetMetricsServicePort,
		}, reqLogger)

	return daemonSet, err
}

func newGlobalnetDaemonSet(cr *v1alpha1.Submariner, name string) *appsv1.DaemonSet {
	labels := map[string]string{
		"app":       name,
		"component": "globalnet",
	}

	return &appsv1.DaemonSet{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: cr.Namespace,
			Name:      name,
			Labels:    labels,
		},
		Spec: appsv1.DaemonSetSpec{
			Selector: &metav1.LabelSelector{MatchLabels: map[string]string{
				"app": name,
			}},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: labels,
				},
				Spec: corev1.PodSpec{
					Volumes: []corev1.Volume{
						{Name: "host-run-xtables-lock", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{
							Path: "/run/xtables.lock",
						}}},
					},
					Containers: []corev1.Container{
						{
							Name:            name,
							Image:           getImagePath(cr, opnames.GlobalnetImage, names.GlobalnetComponent),
							ImagePullPolicy: images.GetPullPolicy(cr.Spec.Version, cr.Spec.ImageOverrides[names.GlobalnetComponent]),
							SecurityContext: &corev1.SecurityContext{
								Capabilities:             &corev1.Capabilities{Add: []corev1.Capability{"ALL"}},
								AllowPrivilegeEscalation: ptr.To(true),
								Privileged:               ptr.To(true),
								ReadOnlyRootFilesystem:   ptr.To(false),
								RunAsNonRoot:             ptr.To(false),
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "host-run-xtables-lock", MountPath: "/run/xtables.lock"},
							},
							Env: httpproxy.AddEnvVars([]corev1.EnvVar{
								{Name: "SUBMARINER_NAMESPACE", Value: cr.Spec.Namespace},
								{Name: "SUBMARINER_CLUSTERID", Value: cr.Spec.ClusterID},
								{Name: "SUBMARINER_METRICSPORT", Value: globalnetMetricsServerPort},
								{Name: "NODE_NAME", ValueFrom: &corev1.EnvVarSource{
									FieldRef: &corev1.ObjectFieldSelector{
										FieldPath: "spec.nodeName",
									},
								}},
							}),
						},
					},
					ServiceAccountName:            names.GlobalnetComponent,
					TerminationGracePeriodSeconds: ptr.To(int64(2)),
					NodeSelector:                  map[string]string{"submariner.io/gateway": "true"},
					HostNetwork:                   true,
					DNSPolicy:                     corev1.DNSClusterFirstWithHostNet,
					// The Globalnet Pod must be able to run on any flagged node, regardless of existing taints
					Tolerations: []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
				},
			},
		},
	}
}

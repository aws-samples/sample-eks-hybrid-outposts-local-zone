# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Rendered by validation/run-tests.sh with VERSION=v1 (Outposts) or v2 (Local Zone).
# The upstream sample image runs as root, so it is only used for this test.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-${VERSION}
  labels:
    app: helloworld
    version: ${VERSION}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
      version: ${VERSION}
  template:
    metadata:
      labels:
        app: helloworld
        version: ${VERSION}
    spec:
      serviceAccountName: helloworld
      automountServiceAccountToken: false
      containers:
        - name: helloworld
          image: docker.io/istio/examples-helloworld-${VERSION}:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /hello
              port: 5000
          livenessProbe:
            httpGet:
              path: /hello
              port: 5000
            periodSeconds: 30

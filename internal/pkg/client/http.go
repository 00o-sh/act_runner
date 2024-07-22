// Copyright 2022 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

package client

import (
	"context"
	"crypto/tls"
	"net/http"
	"strings"

	"code.gitea.io/actions-proto-go/ping/v1/pingv1connect"
	"code.gitea.io/actions-proto-go/runner/v1/runnerv1connect"
	"connectrpc.com/connect"
	log "github.com/sirupsen/logrus"
)

func getHTTPClient(endpoint string, insecure bool, clientcert string, clientkey string) *http.Client {
	var cfg tls.Config
	if strings.HasPrefix(endpoint, "https://") && insecure {
		cfg.InsecureSkipVerify = true
	}

	if len(strings.TrimSpace(clientcert)) > 0 && len(strings.TrimSpace(clientkey)) > 0 {
		// Load client certificate and private key
		clientCert, err := tls.LoadX509KeyPair(clientcert, clientkey)
		if err != nil {
			log.WithError(err).
				Errorln("Error loading client certificate")
		} else {
			cfg.Certificates = []tls.Certificate{clientCert}
		}
	}

	if cfg.InsecureSkipVerify || len(cfg.Certificates) > 0 {
		return &http.Client{
			Transport: &http.Transport{
				TLSClientConfig: &cfg,
			},
		}
	}
	return http.DefaultClient
}

// New returns a new runner client.
func New(endpoint string, insecure bool, clientcert string, clientkey string, uuid, token, version string, opts ...connect.ClientOption) *HTTPClient {
	baseURL := strings.TrimRight(endpoint, "/") + "/api/actions"

	opts = append(opts, connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if uuid != "" {
				req.Header().Set(UUIDHeader, uuid)
			}
			if token != "" {
				req.Header().Set(TokenHeader, token)
			}
			// TODO: version will be removed from request header after Gitea 1.20 released.
			if version != "" {
				req.Header().Set(VersionHeader, version)
			}
			return next(ctx, req)
		}
	})))

	return &HTTPClient{
		PingServiceClient: pingv1connect.NewPingServiceClient(
			getHTTPClient(endpoint, insecure, clientcert, clientkey),
			baseURL,
			opts...,
		),
		RunnerServiceClient: runnerv1connect.NewRunnerServiceClient(
			getHTTPClient(endpoint, insecure, clientcert, clientkey),
			baseURL,
			opts...,
		),
		endpoint:   endpoint,
		insecure:   insecure,
		clientcert: clientcert,
		clientkey:  clientkey,
	}
}

func (c *HTTPClient) Address() string {
	return c.endpoint
}

func (c *HTTPClient) Insecure() bool {
	return c.insecure
}

func (c *HTTPClient) Clientcert() string {
	return c.clientcert
}

func (c *HTTPClient) Clientkey() string {
	return c.clientkey
}

var _ Client = (*HTTPClient)(nil)

// An HTTPClient manages communication with the runner API.
type HTTPClient struct {
	pingv1connect.PingServiceClient
	runnerv1connect.RunnerServiceClient
	endpoint   string
	insecure   bool
	clientcert string
	clientkey  string
}

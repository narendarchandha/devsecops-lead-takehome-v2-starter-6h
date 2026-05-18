package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"

	"github.com/dgrijalva/jwt-go"
	"github.com/gin-gonic/gin"
	"gopkg.in/yaml.v3"
)

// Config is loaded from a YAML file at startup.
type Config struct {
	Addr           string `yaml:"addr"`
	LogLevel       string `yaml:"log_level"`
	SigningKey     string `yaml:"signing_key"`
	BootstrapToken string `yaml:"bootstrap_token"`
}

// Store is the in-memory secret backend.
type Store struct {
	mu    sync.RWMutex
	items map[string]string
}

func newStore() *Store {
	return &Store{items: make(map[string]string)}
}

func (s *Store) put(key, value string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items[key] = value
}

func (s *Store) get(key string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.items[key]
	return v, ok
}

// SecretRequest is the body shape for POST /v1/secrets.
type SecretRequest struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if c.Addr == "" {
		c.Addr = ":8080"
	}
	if c.SigningKey == "" {
		return nil, errors.New("config: signing_key is required")
	}
	return &c, nil
}

func authMiddleware(cfg *Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		header := c.GetHeader("Authorization")
		if len(header) < 8 || header[:7] != "Bearer " {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing bearer token"})
			return
		}
		tokStr := header[7:]
		if tokStr == cfg.BootstrapToken {
			c.Next()
			return
		}
		token, err := jwt.Parse(tokStr, func(t *jwt.Token) (interface{}, error) {
			return []byte(cfg.SigningKey), nil
		})
		if err != nil || !token.Valid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			return
		}
		c.Next()
	}
}

func postSecret(s *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req SecretRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		s.put(req.Key, req.Value)
		log.Printf("stored secret key=%q value=%q", req.Key, req.Value)
		c.JSON(http.StatusCreated, gin.H{"key": req.Key})
	}
}

func getSecret(s *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := c.Param("key")
		v, ok := s.get(key)
		if !ok {
			c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
			return
		}
		log.Printf("retrieved secret key=%q value=%q", key, v)
		c.JSON(http.StatusOK, gin.H{"key": key, "value": v})
	}
}

func healthz(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func readyz(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ready"})
}

func main() {
	configPath := flag.String("config", "", "path to vault-shim config.yaml")
	flag.Parse()

	if *configPath == "" {
		if env := os.Getenv("VAULT_SHIM_CONFIG"); env != "" {
			*configPath = env
		} else {
			*configPath = "config.yaml"
		}
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	store := newStore()

	r := gin.New()
	r.Use(gin.Recovery())

	r.GET("/healthz", healthz)
	r.GET("/readyz", readyz)

	v1 := r.Group("/v1")
	v1.Use(authMiddleware(cfg))
	v1.POST("/secrets", postSecret(store))
	v1.GET("/secrets/:key", getSecret(store))

	log.Printf("vault-shim listening on %s (log_level=%s)", cfg.Addr, cfg.LogLevel)
	if err := r.Run(cfg.Addr); err != nil {
		log.Fatalf("server: %v", err)
	}
}

// Package link, client side: dial out, say hello, hear about work.
//
// The agent always dials out. That single decision is why this works on a phone behind CGNAT, on a
// laptop that changes networks, and on anything you would not port-forward - and it is also the
// honest answer to "why not Nomad", whose agent has to be reachable.
package link

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Executor runs one leased shard. The client owns liveness; the executor owns work.
type Executor func(ctx context.Context, lease Lease, progress func(done, total int)) (Done, error)

// Client is one device's connection to one brain.
type Client struct {
	URL   string // ws://host:port/ws
	Token string
	Facts func() map[string]any
	Run   Executor
	Log   io.Writer

	BeatEvery time.Duration
}

// ConnectAndServe keeps the device enrolled until ctx is cancelled, reconnecting with backoff.
// It returns only when ctx is done or the token is rejected.
func (c *Client) ConnectAndServe(ctx context.Context) error {
	backoff := time.Second

	for {
		err := c.session(ctx)
		if ctx.Err() != nil {
			return nil
		}

		// A rejected token is not a transient fault: reconnecting would just fail more slowly.
		if errors.Is(err, ErrUnauthorized) {
			return err
		}

		c.logf("disconnected: %v (retrying in %s)", err, backoff.Round(time.Second))

		select {
		case <-ctx.Done():
			return nil
		case <-time.After(jitter(backoff)):
		}

		backoff *= 2
		if backoff > 30*time.Second {
			backoff = 30 * time.Second
		}
	}
}

// ErrUnauthorized means the brain refused the join token.
var ErrUnauthorized = errors.New("brain rejected the join token")

func (c *Client) session(ctx context.Context) error {
	dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	options := &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + c.Token}},
	}

	socket, _, err := websocket.Dial(dialCtx, c.URL, options)
	if err != nil {
		return fmt.Errorf("dial %s: %w", c.URL, err)
	}
	defer socket.CloseNow()

	socket.SetReadLimit(1 << 20)

	session := &session{
		client:  c,
		socket:  socket,
		shards:  map[string]context.CancelFunc{},
		writeMu: &sync.Mutex{},
	}

	hello := Hello{Token: c.Token}
	if c.Facts != nil {
		for key, value := range c.Facts() {
			switch key {
			case "host":
				hello.Host, _ = value.(string)
			case "os":
				hello.OS, _ = value.(string)
			case "arch":
				hello.Arch, _ = value.(string)
			case "cores":
				hello.Cores, _ = value.(int)
			case "mem_mb":
				hello.MemMB, _ = value.(int)
			case "disk_free_mb":
				hello.DiskFreeMB, _ = value.(int)
			case "battery":
				hello.Battery, _ = value.(int)
			case "thermal":
				hello.Thermal, _ = value.(string)
			case "agent_version":
				hello.AgentVersion, _ = value.(string)
			}
		}
	}

	hello.AgentVersion = versionString(hello.AgentVersion)

	if err := session.send(ctx, TypeHello, hello); err != nil {
		return err
	}

	return session.readLoop(ctx)
}

type session struct {
	client  *Client
	socket  *websocket.Conn
	writeMu *sync.Mutex

	nodeID string

	mutex  sync.Mutex
	shards map[string]context.CancelFunc
	seq    map[string]int64
}

func (s *session) send(ctx context.Context, messageType string, payload any) error {
	frame, err := Encode(messageType, payload)
	if err != nil {
		return err
	}

	// One writer at a time: progress frames come from shard goroutines while beats come from the
	// heartbeat goroutine, and a websocket does not accept interleaved frames.
	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	writeCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return s.socket.Write(writeCtx, websocket.MessageText, frame)
}

func (s *session) readLoop(ctx context.Context) error {
	beats := s.startHeartbeat(ctx)

	defer func() {
		beats()
		s.mutex.Lock()
		for _, cancel := range s.shards {
			cancel()
		}
		s.shards = map[string]context.CancelFunc{}
		s.mutex.Unlock()
	}()

	for {
		kind, frame, err := s.socket.Read(ctx)
		if err != nil {
			return describeClose(ctx, err)
		}
		if kind != websocket.MessageText {
			continue
		}

		envelope, err := Decode(frame)
		if err != nil {
			return err
		}

		if !KnownType(envelope.Type) {
			// Never ignore an instruction: an unknown "revoke" would leave work running that the
			// brain believes is cancelled.
			return fmt.Errorf("brain sent an unknown message type %q", envelope.Type)
		}

		switch envelope.Type {
		case TypeWelcome:
			var welcome Welcome
			if err := Into(envelope, &welcome); err != nil {
				return err
			}
			s.nodeID = welcome.NodeID
			s.client.logf("joined as %s (protocol %s)", welcome.NodeID, envelope.V)

		case TypeLease:
			var lease Lease
			if err := Into(envelope, &lease); err != nil {
				return err
			}
			s.startShard(ctx, lease)

		case TypeRevoke:
			var revoke Revoke
			if err := Into(envelope, &revoke); err != nil {
				return err
			}
			s.stopShard(revoke.ShardID)

		case TypeCancel:
			var cancelMessage Cancel
			if err := Into(envelope, &cancelMessage); err != nil {
				return err
			}
			s.client.logf("brain cancelled job %s", cancelMessage.JobID)
			s.stopAll()
		}
	}
}

func (s *session) startShard(ctx context.Context, lease Lease) {
	shardCtx, cancel := context.WithCancel(ctx)

	s.mutex.Lock()
	if _, running := s.shards[lease.ShardID]; running {
		// A second lease for the same shard means the brain considers the first one dead. Starting it
		// twice would be the duplicate work the whole design exists to avoid.
		s.mutex.Unlock()
		cancel()
		return
	}
	s.shards[lease.ShardID] = cancel
	s.mutex.Unlock()

	go func() {
		defer func() {
			s.mutex.Lock()
			delete(s.shards, lease.ShardID)
			s.mutex.Unlock()
			cancel()
		}()

		s.client.logf("lease %s (%d inputs, attempt %d)", lease.ShardID, len(lease.Inputs), lease.Attempt)

		if err := s.send(ctx, TypeAck, Ack{ShardID: lease.ShardID}); err != nil {
			return
		}

		last := time.Now()
		progress := func(done, total int) {
			// Throttle: a progress frame per input would be a frame flood for a shard of thousands.
			if time.Since(last) < 250*time.Millisecond && done != total {
				return
			}
			last = time.Now()
			_ = s.send(ctx, TypeProgress, Progress{ShardID: lease.ShardID, Done: done, Total: total})
		}

		result, err := s.client.Run(shardCtx, lease, progress)
		if err != nil {
			_ = s.send(ctx, TypeFail, Fail{ShardID: lease.ShardID, Error: err.Error(), ExitCode: 1})
			s.client.logf("shard %s failed: %v", lease.ShardID, err)
			return
		}

		if err := s.send(ctx, TypeDone, result); err != nil {
			return
		}
		s.client.logf("shard %s done (%d inputs, %s)", lease.ShardID, result.InputsDone, time.Duration(result.DurationMS)*time.Millisecond)
	}()
}

func (s *session) stopShard(shardID string) {
	s.mutex.Lock()
	cancel, ok := s.shards[shardID]
	s.mutex.Unlock()

	if ok {
		cancel()
		s.client.logf("brain revoked %s; stopping", shardID)
	}
}

func (s *session) stopAll() {
	s.mutex.Lock()
	cancels := make([]context.CancelFunc, 0, len(s.shards))
	for _, cancel := range s.shards {
		cancels = append(cancels, cancel)
	}
	s.mutex.Unlock()

	for _, cancel := range cancels {
		cancel()
	}
}

// startHeartbeat sends the first beat immediately, then on an interval. The brain's lease deadline
// depends on these arriving; a silent device is treated as gone, by design.
func (s *session) startHeartbeat(ctx context.Context) func() {
	interval := s.client.BeatEvery
	if interval <= 0 {
		interval = 5 * time.Second
	}

	beatCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})

	go func() {
		defer close(done)

		sendBeat := func() {
			s.mutex.Lock()
			running := make([]string, 0, len(s.shards))
			seq := make(map[string]int64, len(s.seq))
			for shardID := range s.shards {
				running = append(running, shardID)
			}
			for shardID, value := range s.seq {
				seq[shardID] = value
			}
			s.mutex.Unlock()

			payload := Beat{TS: time.Now().UTC().Format(time.RFC3339), Running: running, Seq: seq, Battery: -1, Thermal: "unknown"}

			if s.client.Facts != nil {
				f := s.client.Facts()
				if battery, ok := f["battery"].(int); ok {
					payload.Battery = battery
				}
				if thermal, ok := f["thermal"].(string); ok {
					payload.Thermal = thermal
				}
			}

			_ = s.send(beatCtx, TypeBeat, payload)
		}

		sendBeat()
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-beatCtx.Done():
				return
			case <-ticker.C:
				sendBeat()
			}
		}
	}()

	return func() {
		cancel()
		<-done
	}
}

func describeClose(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}

	status := websocket.CloseStatus(err)
	switch status {
	case websocket.StatusPolicyViolation, websocket.StatusUnsupportedData:
		// 1008 is how the brain says "bad token or bad protocol": retrying cannot fix it.
		return fmt.Errorf("%w (%v)", ErrUnauthorized, err)
	case websocket.StatusNormalClosure:
		return fmt.Errorf("brain closed the connection")
	}

	return err
}

func (c *Client) logf(format string, args ...any) {
	if c.Log == nil {
		return
	}
	fmt.Fprintf(c.Log, "%s %s\n", time.Now().Format("15:04:05"), fmt.Sprintf(format, args...))
}

func versionString(value string) string {
	if strings.TrimSpace(value) == "" {
		return "dev"
	}
	return value
}

// jitter adds up to 20% so a fleet reconnecting after a brain restart does not arrive in lockstep.
func jitter(d time.Duration) time.Duration {
	return d + time.Duration(rand.Int63n(int64(d/5)+1)) //nolint:gosec // timing only
}

// Package media takes photos and records videos from the robot's camera
// into a folder on the SD card's data partition, for the app's gallery.
//
// It reads MediaMTX's local RTSP stream with ffmpeg: a recording copies the
// H.264 the Pi's hardware encoder already makes (no CPU spent re-encoding),
// a photo decodes a single frame. Each item gets a small JPEG thumbnail in
// .thumbs/ for the gallery grid.
package media

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Item is one photo or video in the gallery.
type Item struct {
	Name      string    `json:"name"`
	Kind      string    `json:"kind"` // "photo" or "video"
	Size      int64     `json:"size"` // bytes
	Created   time.Time `json:"created"`
	DurationS int       `json:"duration_s,omitempty"` // videos
}

// Status of the gallery and the recorder.
type Status struct {
	Recording  bool   `json:"recording"`
	RecordingS int    `json:"recording_s,omitempty"` // seconds so far
	FreeMB     uint64 `json:"free_mb"`
	Items      []Item `json:"items"`
}

// Errors the API turns into answers for the app.
var (
	ErrNoSpace   = errors.New("not enough free space on the SD card")
	ErrRecording = errors.New("already recording")
	ErrNotFound  = errors.New("no such item")
	ErrCamera    = errors.New("the camera did not answer")
)

// Options for the Gallery.
type Options struct {
	Dir       string        // /opt/hexapod/shared/media
	Source    string        // rtsp://127.0.0.1:8554/cam
	FFmpeg    string        // ffmpeg binary (tests use a fake)
	MaxRecord time.Duration // a recording stops by itself after this long
	MinFreeMB uint64        // below this no photo or recording starts, and a recording stops
	Log       *slog.Logger
	Now       func() time.Time
}

// Gallery owns the media folder. Safe for concurrent use.
type Gallery struct {
	opt Options

	mu    sync.Mutex
	rec   *exec.Cmd
	stdin io.WriteCloser
	part  string // file being recorded (.part)
	final string // its name once finished
	start time.Time
	done  chan struct{} // closed when the recording's ffmpeg exits
}

var nameRE = regexp.MustCompile(`^(photo|video)-\d{8}-\d{6}(-\d+)?\.(jpg|mp4)$`)

// New prepares the folder.
func New(opt Options) (*Gallery, error) {
	if opt.FFmpeg == "" {
		opt.FFmpeg = "ffmpeg"
	}
	if opt.Now == nil {
		opt.Now = time.Now
	}
	if opt.Log == nil {
		opt.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if err := os.MkdirAll(filepath.Join(opt.Dir, ".thumbs"), 0o755); err != nil {
		return nil, err
	}
	// A recording cut by a power loss leaves a .part: keep what was saved.
	parts, _ := filepath.Glob(filepath.Join(opt.Dir, "*.part"))
	for _, p := range parts {
		_ = os.Rename(p, strings.TrimSuffix(p, ".part"))
	}
	return &Gallery{opt: opt}, nil
}

func (g *Gallery) freeMB() uint64 {
	var fs syscall.Statfs_t
	if syscall.Statfs(g.opt.Dir, &fs) != nil {
		return 0
	}
	return fs.Bavail * uint64(fs.Bsize) >> 20
}

// newName: kind-YYYYMMDD-HHMMSS.ext, with a suffix if taken.
func (g *Gallery) newName(kind, ext string) string {
	base := kind + "-" + g.opt.Now().Format("20060102-150405")
	name := base + "." + ext
	for i := 2; ; i++ {
		if _, err := os.Stat(filepath.Join(g.opt.Dir, name)); errors.Is(err, os.ErrNotExist) {
			return name
		}
		name = fmt.Sprintf("%s-%d.%s", base, i, ext)
	}
}

func (g *Gallery) thumbPath(name string) string {
	return filepath.Join(g.opt.Dir, ".thumbs", strings.TrimSuffix(name, filepath.Ext(name))+".jpg")
}

func (g *Gallery) ffmpeg(ctx context.Context, args ...string) error {
	full := append([]string{"-hide_banner", "-loglevel", "error", "-y"}, args...)
	out, err := exec.CommandContext(ctx, g.opt.FFmpeg, full...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %v: %s", ErrCamera, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Photo saves one frame of the camera, with its thumbnail.
func (g *Gallery) Photo(ctx context.Context) (Item, error) {
	if g.freeMB() < g.opt.MinFreeMB {
		return Item{}, ErrNoSpace
	}
	name := g.newName("photo", "jpg")
	path := filepath.Join(g.opt.Dir, name)
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	err := g.ffmpeg(ctx, "-rtsp_transport", "tcp", "-i", g.opt.Source,
		"-frames:v", "1", "-q:v", "2", path,
		"-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", g.thumbPath(name))
	if err != nil {
		_ = os.Remove(path)
		return Item{}, err
	}
	g.opt.Log.Info("photo", "name", name)
	return g.item(name)
}

// StartRecording copies the camera stream into an MP4 until StopRecording,
// MaxRecord, or the card runs low on space.
func (g *Gallery) StartRecording() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.rec != nil {
		return ErrRecording
	}
	if g.freeMB() < g.opt.MinFreeMB {
		return ErrNoSpace
	}
	name := g.newName("video", "mp4")
	part := filepath.Join(g.opt.Dir, name+".part")
	args := []string{"-hide_banner", "-loglevel", "error", "-y",
		"-rtsp_transport", "tcp", "-i", g.opt.Source, "-c", "copy",
		// Fragmented MP4: playable up to the last second written, even when
		// a power cut ends the recording without closing the file.
		"-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4"}
	if g.opt.MaxRecord > 0 {
		args = append(args, "-t", fmt.Sprintf("%.0f", g.opt.MaxRecord.Seconds()))
	}
	cmd := exec.Command(g.opt.FFmpeg, append(args, part)...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("%w: %v", ErrCamera, err)
	}
	g.rec, g.stdin, g.part, g.final, g.start = cmd, stdin, part, name, g.opt.Now()
	done := make(chan struct{})
	g.done = done
	go func() {
		err := cmd.Wait()
		g.finish(err, stderr.String())
		close(done)
	}()
	go g.watch(done)
	g.opt.Log.Info("recording", "name", name)
	return nil
}

// watch stops the recording when the card runs low on space.
func (g *Gallery) watch(done chan struct{}) {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			if g.freeMB() < g.opt.MinFreeMB {
				g.opt.Log.Warn("recording stopped: SD card almost full")
				_, _ = g.StopRecording()
				return
			}
		}
	}
}

// finish runs when ffmpeg exits (stopped, time limit, or failure).
func (g *Gallery) finish(err error, stderr string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	part, name := g.part, g.final
	g.rec, g.stdin, g.part = nil, nil, ""
	if st, statErr := os.Stat(part); statErr != nil || st.Size() == 0 {
		_ = os.Remove(part)
		g.opt.Log.Warn("recording failed", "err", err, "ffmpeg", strings.TrimSpace(stderr))
		return
	}
	final := filepath.Join(g.opt.Dir, name)
	if err := os.Rename(part, final); err != nil {
		g.opt.Log.Warn("recording not saved", "err", err)
		return
	}
	// Thumbnail from the first second (best effort).
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := g.ffmpeg(ctx, "-i", final, "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", g.thumbPath(name)); err != nil {
		g.opt.Log.Warn("video thumbnail", "err", err)
	}
	g.opt.Log.Info("recording saved", "name", name)
}

// StopRecording ends the recording cleanly ("q" makes ffmpeg flush the last
// fragment) and waits for the file.
func (g *Gallery) StopRecording() (Item, error) {
	g.mu.Lock()
	cmd, stdin, done, name := g.rec, g.stdin, g.done, g.final
	g.mu.Unlock()
	if cmd == nil {
		return Item{}, nil
	}
	_, _ = io.WriteString(stdin, "q")
	_ = stdin.Close()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
	return g.item(name)
}

// Recording: whether a recording runs and for how long.
func (g *Gallery) Recording() (bool, time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.rec == nil {
		return false, 0
	}
	return true, g.opt.Now().Sub(g.start)
}

// Status lists the gallery, newest first.
func (g *Gallery) Status() (Status, error) {
	on, for_ := g.Recording()
	st := Status{Recording: on, RecordingS: int(for_.Seconds()), FreeMB: g.freeMB(), Items: []Item{}}
	entries, err := os.ReadDir(g.opt.Dir)
	if err != nil {
		return st, err
	}
	for _, e := range entries {
		if !nameRE.MatchString(e.Name()) {
			continue
		}
		if it, err := g.item(e.Name()); err == nil {
			st.Items = append(st.Items, it)
		}
	}
	sort.Slice(st.Items, func(i, j int) bool { return st.Items[i].Name > st.Items[j].Name })
	sort.SliceStable(st.Items, func(i, j int) bool { return st.Items[i].Created.After(st.Items[j].Created) })
	return st, nil
}

func (g *Gallery) item(name string) (Item, error) {
	if !nameRE.MatchString(name) {
		return Item{}, ErrNotFound
	}
	info, err := os.Stat(filepath.Join(g.opt.Dir, name))
	if err != nil {
		return Item{}, ErrNotFound
	}
	kind := strings.SplitN(name, "-", 2)[0]
	stamp := strings.SplitN(name, "-", 2)[1][:15] // YYYYMMDD-HHMMSS
	created, err := time.ParseInLocation("20060102-150405", stamp, time.Local)
	if err != nil {
		created = info.ModTime()
	}
	it := Item{Name: name, Kind: kind, Size: info.Size(), Created: created}
	if kind == "video" {
		if d := info.ModTime().Sub(created); d > 0 {
			it.DurationS = int(d.Round(time.Second).Seconds())
		}
	}
	return it, nil
}

// Path is where an item (or its thumbnail) is, for serving it.
func (g *Gallery) Path(name string, thumb bool) (string, error) {
	if _, err := g.item(name); err != nil {
		return "", err
	}
	if thumb {
		p := g.thumbPath(name)
		if _, err := os.Stat(p); err != nil {
			return "", ErrNotFound
		}
		return p, nil
	}
	return filepath.Join(g.opt.Dir, name), nil
}

// Delete removes an item and its thumbnail.
func (g *Gallery) Delete(name string) error {
	if _, err := g.item(name); err != nil {
		return err
	}
	g.mu.Lock()
	busy := g.rec != nil && g.final == name
	g.mu.Unlock()
	if busy {
		return ErrRecording
	}
	_ = os.Remove(g.thumbPath(name))
	return os.Remove(filepath.Join(g.opt.Dir, name))
}

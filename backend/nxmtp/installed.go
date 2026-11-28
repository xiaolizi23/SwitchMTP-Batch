// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.

package nxmtp

import (
	"bytes"
	"encoding/csv"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

// InstalledTitle is one row from the responder's installed-applications
// manifest CSV. Title IDs are normalized to the bare uppercase form (no 0x
// prefix, no spaces) so they can be compared directly against local packages.
type InstalledTitle struct {
	TitleID string `json:"titleId"`
	Version int64  `json:"version"`
	Name    string `json:"name"`
}

// InstalledEntry is one installable item DBI exposes under the installed-games
// virtual storage. Its kind is read from the entry filename's [Base] /
// [Update] / [DLC n] tag, not inferred from the title id suffix.
type InstalledEntry struct {
	TitleID string `json:"titleId"`
	Kind    string `json:"kind"`
	Version int64  `json:"version"`
	Name    string `json:"name"`
}

// InstalledManifest aggregates the two signals available over MTP. The
// directory entries are the stronger base-game signal: a base title only gets a
// [Base] entry when its content is actually present. The CSV is a startup
// index that update/DLC installs and stale leftovers can populate with a base
// row, so CSV base rows are not trusted on their own. Pure DLC titles never
// get a directory entry, so the CSV remains the only DLC signal.
type InstalledManifest struct {
	// CSVTitles is the raw InstalledApplications.csv rows. Used for DLC
	// matching and as a fallback reference; do not match base games off it.
	CSVTitles []InstalledTitle `json:"csvTitles"`
	// BaseIDs are title ids with a [Base] directory entry.
	BaseIDs []string `json:"baseIds"`
	// DLCIDs are title ids with a [DLC] directory entry (enhancement to the
	// CSV DLC match; pure DLCs only appear in CSVTitles).
	DLCIDs []string `json:"dlcIds"`
}

const (
	entryKindBase   = "base"
	entryKindUpdate = "update"
	entryKindDLC    = "dlc"
)

// installedCSVPath is the manifest DBI publishes in its installed-games
// virtual storage. Rows look like:
//
//	0x010081A00EE62000,1507328,"Game Title"
const installedCSVPath = "/InstalledApplications.csv"

// installedGamesSID is the responder's installed-applications virtual storage
// id. It is matched first by numeric id, then by KindInstalledGames, so a
// responder that renumbers the storage still resolves.
const installedGamesSID uint32 = 65540

var (
	dirEntryTitleIDRe = regexp.MustCompile(`\[([0-9A-Fa-f]{16})\]`)
	dirEntryVersionRe = regexp.MustCompile(`\[v(\d+)\]`)
)

// InstalledManifest reads the installed-games virtual storage: it walks the
// directory tree for [Base]/[DLC] entries and parses the CSV manifest for
// DLC rows and fallback reference.
//
// The CSV and directory tree are startup snapshots the responder writes when
// it starts; a freshly installed title may not appear until the responder
// restarts, and the virtual storage only exposes a partial view. Unreadable
// storage or a missing manifest yields empty sets rather than an error, so the
// install flow falls back to "no duplicates known" instead of showing a
// blocking banner over a normal run.
func (c *Client) InstalledManifest() (InstalledManifest, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	var m InstalledManifest
	if err := c.refreshStorages(); err != nil {
		return m, err
	}

	st := c.findInstalledGamesStorageLocked()
	if st == nil {
		return m, nil
	}

	baseSeen, dlcSeen := map[string]struct{}{}, map[string]struct{}{}
	c.collectInstalledEntriesLocked(st.Sid, ParentRoot, baseSeen, dlcSeen)
	m.BaseIDs = sortedKeySet(baseSeen)
	m.DLCIDs = sortedKeySet(dlcSeen)

	m.CSVTitles = c.readInstalledCSVLocked(st)
	return m, nil
}

// collectInstalledEntriesLocked recursively lists the installed-games tree,
// collecting base and DLC title ids from parseable entry filenames. Callers
// must hold c.mu; it uses listRaw directly so it does not re-take the lock
// the way the high-level Walk does.
func (c *Client) collectInstalledEntriesLocked(sid, parent uint32, base, dlc map[string]struct{}) {
	entries, err := c.listRaw(sid, parent)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsFolder {
			c.collectInstalledEntriesLocked(sid, e.Handle, base, dlc)
			continue
		}
		entry, ok := parseDirEntry(e.Name)
		if !ok {
			continue
		}
		switch entry.Kind {
		case entryKindBase:
			base[entry.TitleID] = struct{}{}
		case entryKindDLC:
			dlc[entry.TitleID] = struct{}{}
		}
	}
}

// readInstalledCSVLocked downloads and parses the CSV manifest. A missing or
// unreadable CSV yields nil rather than failing the whole manifest.
func (c *Client) readInstalledCSVLocked(st *Storage) []InstalledTitle {
	node, err := c.resolvePath(st.Sid, installedCSVPath)
	if err != nil || node.isFolder {
		return nil
	}
	var buf bytes.Buffer
	if err := c.t.GetObject(node.handle, &buf, mtp.EmptyProgressFunc); err != nil {
		return nil
	}
	return parseInstalledCSV(buf.Bytes())
}

// findInstalledGamesStorageLocked returns the installed-games virtual storage.
// Callers must hold c.mu.
func (c *Client) findInstalledGamesStorageLocked() *Storage {
	for i := range c.storages {
		if c.storages[i].Sid == installedGamesSID {
			return &c.storages[i]
		}
	}
	for i := range c.storages {
		if c.storages[i].Kind == KindInstalledGames {
			return &c.storages[i]
		}
	}
	return nil
}

// parseDirEntry extracts the title id, version and kind from a DBI entry
// filename such as:
//
//	Game Title [01004EA00DF70000][v0][Base].nsp
//	Game Title [010081A00EE63001][v720896][DLC 1].nsp
//
// The aggregated on-demand dump (e.g. "[B+U1507328+1DLC].nsp") has no 16-digit
// title id and is rejected. An unrecognized tag is rejected too, rather than
// guessed.
func parseDirEntry(name string) (InstalledEntry, bool) {
	m := dirEntryTitleIDRe.FindStringSubmatch(name)
	if m == nil {
		return InstalledEntry{}, false
	}
	titleID := NormalizeTitleID(m[1])
	if titleID == "" {
		return InstalledEntry{}, false
	}

	kind := ""
	switch {
	case strings.Contains(name, "[Base]"):
		kind = entryKindBase
	case strings.Contains(name, "[Update]"):
		kind = entryKindUpdate
	case strings.Contains(name, "[DLC"):
		kind = entryKindDLC
	default:
		return InstalledEntry{}, false
	}

	var version int64
	if vm := dirEntryVersionRe.FindStringSubmatch(name); vm != nil {
		version, _ = strconv.ParseInt(vm[1], 10, 64)
	}

	return InstalledEntry{
		TitleID: titleID,
		Kind:    kind,
		Version: version,
		Name:    strings.TrimSpace(name),
	}, true
}

// parseInstalledCSV reads the manifest into normalized titles. Malformed rows
// are skipped rather than failing the whole list; an unparseable file yields
// an empty slice.
func parseInstalledCSV(raw []byte) []InstalledTitle {
	out := []InstalledTitle{}
	reader := csv.NewReader(bytes.NewReader(raw))
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true

	records, err := reader.ReadAll()
	if err != nil && records == nil {
		return out
	}

	for _, row := range records {
		if len(row) == 0 {
			continue
		}
		id := NormalizeTitleID(row[0])
		if id == "" {
			continue
		}
		var version int64
		if len(row) >= 2 {
			version, _ = strconv.ParseInt(strings.TrimSpace(row[1]), 10, 64)
		}
		name := ""
		if len(row) >= 3 {
			name = strings.TrimSpace(row[2])
		}
		out = append(out, InstalledTitle{TitleID: id, Version: version, Name: name})
	}
	return out
}

// NormalizeTitleID strips the 0x prefix and any whitespace and upper-cases a
// title ID, so CSV rows and local package IDs compare equal regardless of how
// they were written.
func NormalizeTitleID(s string) string {
	t := strings.TrimSpace(s)
	t = strings.TrimPrefix(t, "0x")
	t = strings.TrimPrefix(t, "0X")
	t = strings.ToUpper(t)
	return strings.ReplaceAll(t, " ", "")
}

func sortedKeySet(set map[string]struct{}) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

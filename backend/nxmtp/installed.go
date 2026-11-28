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
	"strconv"
	"strings"

	"github.com/ganeshrvel/go-mtpfs/mtp"
)

// InstalledTitle is one row from the responder's installed-applications
// manifest. Title IDs are normalized to the bare uppercase form (no 0x prefix,
// no spaces) so they can be compared directly against local packages.
type InstalledTitle struct {
	TitleID string `json:"titleId"`
	Version int64  `json:"version"`
	Name    string `json:"name"`
}

// installedCSVPath is the manifest DBI publishes in its installed-games
// virtual storage. Rows look like:
//
//	0x010081A00EE62000,1507328,"Boomerang Fu"
const installedCSVPath = "/InstalledApplications.csv"

// installedGamesSID is the responder's installed-applications virtual storage
// id. It is matched first by numeric id, then by KindInstalledGames, so a
// responder that renumbers the storage still resolves.
const installedGamesSID uint32 = 65540

// InstalledTitles downloads and parses the responder's installed-applications
// manifest.
//
// The CSV is a snapshot the responder wrote when it started: a freshly
// installed title may not appear until the responder restarts, and the
// virtual storage only exposes a partial view. A missing manifest or an
// unreadable virtual storage yields an empty list rather than an error, so the
// install flow can fall back to "no duplicates known" instead of showing a
// blocking banner over a normal run.
func (c *Client) InstalledTitles() ([]InstalledTitle, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.refreshStorages(); err != nil {
		return nil, err
	}

	st := c.findInstalledGamesStorageLocked()
	if st == nil {
		return []InstalledTitle{}, nil
	}

	node, err := c.resolvePath(st.Sid, installedCSVPath)
	if err != nil {
		if KindOf(err) == KindNotFound {
			return []InstalledTitle{}, nil
		}
		return nil, err
	}
	if node.isFolder {
		return []InstalledTitle{}, nil
	}

	var buf bytes.Buffer
	if err := c.t.GetObject(node.handle, &buf, mtp.EmptyProgressFunc); err != nil {
		return nil, err
	}
	return parseInstalledCSV(buf.Bytes()), nil
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

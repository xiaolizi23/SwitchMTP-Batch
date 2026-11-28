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

import "testing"

func TestParseInstalledCSV(t *testing.T) {
	raw := []byte(`0x010081A00EE62000,1507328,"Boomerang Fu"
0x010081A00EE63001,720896,"Boomerang Fu DLC 1"
,0,"empty id row skipped"
0X0100ABCDEF123456,0,"mixed case"
`)

	titles := parseInstalledCSV(raw)
	if len(titles) != 3 {
		t.Fatalf("want 3 titles, got %d: %+v", len(titles), titles)
	}

	first := titles[0]
	if first.TitleID != "010081A00EE62000" || first.Version != 1507328 || first.Name != "Boomerang Fu" {
		t.Errorf("first row = %+v", first)
	}
	if titles[1].TitleID != "010081A00EE63001" || titles[1].Name != "Boomerang Fu DLC 1" {
		t.Errorf("dlc row = %+v", titles[1])
	}
	if titles[2].TitleID != "0100ABCDEF123456" {
		t.Errorf("mixed-case row = %+v", titles[2])
	}
}

func TestParseInstalledCSVEmpty(t *testing.T) {
	if titles := parseInstalledCSV(nil); len(titles) != 0 {
		t.Errorf("nil input should yield empty, got %d", len(titles))
	}
	if titles := parseInstalledCSV([]byte("not,a,csv\n")); len(titles) == 0 {
		// A malformed file must not panic; rows with an empty id are dropped.
		return
	}
}

func TestNormalizeTitleID(t *testing.T) {
	cases := map[string]string{
		"0x0100ABCDEF123456":  "0100ABCDEF123456",
		"0X0100abcdef123456":  "0100ABCDEF123456",
		" 0100 ABC DEF 800 ":  "0100ABCDEF800",
		"":                     "",
	}
	for in, want := range cases {
		if got := NormalizeTitleID(in); got != want {
			t.Errorf("NormalizeTitleID(%q) = %q, want %q", in, got, want)
		}
	}
}

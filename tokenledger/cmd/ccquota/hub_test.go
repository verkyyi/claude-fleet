package main

import (
	"reflect"
	"testing"
)

func TestBindHosts(t *testing.T) {
	got := bindHosts("127.0.0.1:8787, 100.85.129.58:8787,[::1]:8787,garbage")
	want := []string{"127.0.0.1", "100.85.129.58", "::1"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("bindHosts = %v, want %v", got, want)
	}
}

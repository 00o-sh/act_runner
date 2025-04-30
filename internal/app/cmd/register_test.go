package cmd

import (
	"testing"

	"gotest.tools/v3/assert"
)

func TestRegisterNonInteractiveReturnsLabelValidationError(t *testing.T) {
	err := registerNoInteractive(t.Context(), "", &registerArgs{
		Labels:       "label:invalid",
		Token:        "token",
		InstanceAddr: "http://localhost:3000",
	})
	assert.Error(t, err, "unsupported schema: invalid")
}

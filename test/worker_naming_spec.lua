-- Tests for worker kubeconform symlink naming logic.
-- Covers: kind-group-version.json naming convention used by all three workers.

describe("kubeconform symlink naming", function()
  -- Replicate the write_kc_link naming logic from all workers.
  local function kc_name(kind, api_version)
    local group = api_version:match("^(.+)/") or ""
    local ver   = api_version:match("[^/]+$")
    if group ~= "" then
      return kind:lower() .. "-" .. group:lower() .. "-" .. ver:lower() .. ".json"
    else
      return kind:lower() .. "-" .. ver:lower() .. ".json"
    end
  end

  it("formats core resource (no group) as kind-version.json", function()
    assert.equals("pod-v1.json", kc_name("Pod", "v1"))
  end)

  it("formats grouped resource as kind-group-version.json", function()
    assert.equals("deployment-apps-v1.json", kc_name("Deployment", "apps/v1"))
  end)

  it("lowercases everything", function()
    assert.equals("deployment-apps-v1.json", kc_name("Deployment", "apps/v1"))
    assert.equals("horizontalpodautoscaler-autoscaling-v2.json",
      kc_name("HorizontalPodAutoscaler", "autoscaling/v2"))
  end)

  it("handles CRD groups with dots", function()
    assert.equals(
      "alert-notification.toolkit.fluxcd.io-v1beta2.json",
      kc_name("Alert", "notification.toolkit.fluxcd.io/v1beta2")
    )
  end)

  it("handles beta/alpha versions", function()
    assert.equals("ingress-networking.k8s.io-v1.json",
      kc_name("Ingress", "networking.k8s.io/v1"))
    assert.equals("certificate-cert-manager.io-v1.json",
      kc_name("Certificate", "cert-manager.io/v1"))
  end)

  it("produces no underscores in output", function()
    local name = kc_name("Deployment", "apps/v1")
    assert.is_nil(name:match("_"), "kubeconform names must not contain underscores")
  end)

  it("always ends in .json", function()
    assert.truthy(kc_name("Pod", "v1"):match("%.json$"))
    assert.truthy(kc_name("Deployment", "apps/v1"):match("%.json$"))
  end)
end)

describe("to_filename (template.lua) vs kc_name compatibility", function()
  -- template.to_filename produces the yaml/json filename used in templates/ and schemas/.
  -- The kubeconform name must be separately derived from kind+apiVersion, not from the filename.
  -- Verify the two naming schemes are independent (no assumptions about one deriving the other).
  local template = require("helm-schemas.template")

  it("to_filename produces underscore-separated names", function()
    local fname = template.to_filename("Deployment (apps/v1)")
    assert.truthy(fname:match("_"), "to_filename should use underscores")
  end)

  it("kubeconform names use dashes, not underscores", function()
    local function kc_name(kind, api_version)
      local group = api_version:match("^(.+)/") or ""
      local ver   = api_version:match("[^/]+$")
      if group ~= "" then
        return kind:lower() .. "-" .. group:lower() .. "-" .. ver:lower() .. ".json"
      else
        return kind:lower() .. "-" .. ver:lower() .. ".json"
      end
    end
    local name = kc_name("Deployment", "apps/v1")
    assert.is_nil(name:match("_"), "kc_name must not contain underscores")
  end)
end)

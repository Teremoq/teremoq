{
  "subject": {{ toJson .Subject }},
  "sans": {{ toJson .SANs }},
  "keyUsage": ["digitalSignature"],
  "extKeyUsage": ["serverAuth", "clientAuth"],
  "basicConstraints": {
    "isCA": false
  }
}

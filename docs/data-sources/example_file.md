---
page_title: "yourprovider_example_file Data Source"
description: |-
  Reads a text file on the machine running the provider. Sample data source -
  delete this page along with the sample folders.
---

# yourprovider_example_file (Data Source)

Reads a text file.

## Example Usage

```terraform
data "yourprovider_example_file" "config" {
  path = "settings.txt"
}

output "content" {
  value = data.yourprovider_example_file.config.content
}
```

## Schema

### Required

- `path` (String) Path of the file to read.

### Read-Only

- `exists` (Boolean) Whether the file exists.
- `content` (String) File content; null when the file does not exist.
- `size` (Number) Size in bytes; null when the file does not exist.

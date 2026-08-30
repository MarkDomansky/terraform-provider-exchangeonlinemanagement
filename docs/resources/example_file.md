---
page_title: "yourprovider_example_file Resource"
description: |-
  Manages a text file on the machine running the provider. Sample resource -
  delete this page along with the sample folders.
---

# yourprovider_example_file (Resource)

Manages a text file. This is the template's working sample; it exists so you
can see the whole pattern run end to end before writing your own resources.

## Example Usage

```terraform
resource "yourprovider_example_file" "hello" {
  path    = "hello.txt" # relative to the provider's default_directory
  content = "Hello!"
}
```

## Schema

### Required

- `path` (String) Path of the file. Changing it replaces the resource.

### Optional

- `content` (String) Content written to the file; changes update in place.

### Read-Only

- `id` (String) Absolute path of the managed file.
- `size` (Number) File size in bytes.
- `last_modified` (String) Last write time (UTC, ISO 8601).

## Import

```shell
terraform import yourprovider_example_file.hello /full/path/to/hello.txt
```

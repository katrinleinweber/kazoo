## Sleep

### About Sleep

#### Schema

Validator for the sleep callflow's data object



Key | Description | Type | Default | Required
--- | ----------- | ---- | ------- | --------
`duration` | How long to pause before continuing the callflow | `integer()` | `0` | `false`
`unit` | What time unit is 'duration' in | `string('ms' | 's' | 'm' | 'h')` | `s` | `false`




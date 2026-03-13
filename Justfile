# cairn — stones stacked to mark passage
#
# The witness API. Becomes an MCP server via just_beam.
# Humans can leave cairns too.

# Initialize a cairn in the current directory
init:
    fragmentation init .cairn

# Observe: record what you see
observe ANNOTATION DATA:
    fragmentation write --type observation --annotation "{{ANNOTATION}}" "{{DATA}}"

# Decide: record a decision with reference to observation
decide ANNOTATION OBS_REF RULE:
    fragmentation write --type decision --annotation "{{ANNOTATION}}" --ref "{{OBS_REF}}" "{{RULE}}"

# Act: record an action
act ANNOTATION DATA:
    fragmentation write --type action --annotation "{{ANNOTATION}}" "{{DATA}}"

# Record cognitive bias observation
bias CATEGORY DETAIL:
    fragmentation write --type bias --category "{{CATEGORY}}" "{{DETAIL}}"

# Commit the current session
commit MESSAGE:
    fragmentation commit "{{MESSAGE}}"

# Verify store integrity
verify:
    fragmentation verify .cairn

# Show cairn status
status:
    fragmentation status .cairn

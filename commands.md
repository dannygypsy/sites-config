

# Update the latest from GIT (from /opt/sites)
% git pull


# Check stats on server

% docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
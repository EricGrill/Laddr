# Laddr Dashboard

The official Laddr dashboard, distributed as a Docker image for seamless integration with Laddr projects.

## 🎯 Overview

This directory contains the React-based dashboard that provides comprehensive observability for Laddr agent systems. The dashboard is built and distributed as a Docker image (`laddr/dashboard:latest`) so users never need to touch frontend code.

## 🏗️ Architecture

```
dashboard/
├── src/                  # React application source
│   ├── App.tsx          # Main application component
│   ├── main.tsx         # Application entry point
│   └── ...
├── public/              # Static assets
├── Dockerfile           # Development Dockerfile
├── Dockerfile.prod      # Production Dockerfile (multi-stage)
├── nginx.conf           # Nginx configuration for production
├── vite.config.ts       # Vite build configuration
├── package.json         # Dependencies and scripts
└── build-dashboard.sh   # Build script for Docker image
```

## 📦 Distribution Model

### For Users
- Dashboard is **NOT** copied to user projects
- Distributed as pre-built Docker image
- Automatically pulled when running `laddr run dev`
- Zero frontend setup required

### For Maintainers
- Build and publish Docker images to Docker Hub
- Multi-stage build: Node.js → Nginx
- Optimized for production (~40MB final size)

## 🚀 Building the Dashboard

### Development

```bash
# Install dependencies
npm install

# Run development server
npm run dev
# Dashboard available at http://localhost:5173

# Build for production
npm run build
# Output in dist/
```

### Production Docker Image

```bash
# Build Docker image
./build-dashboard.sh v1.0.0

# Or manually
docker build -f Dockerfile.prod -t laddr/dashboard:latest .

# Test locally
docker run -p 5173:5173 laddr/dashboard:latest

# Push to Docker Hub
docker push laddr/dashboard:latest
docker push laddr/dashboard:v1.0.0
```

## 🔧 Technical Details

### Multi-Stage Build

**Stage 1: Builder**
- Base: `node:20-alpine`
- Installs dependencies with `npm ci`
- Builds React app with Vite
- Output: Optimized static files

**Stage 2: Server**
- Base: `nginx:alpine`
- Copies built files from builder
- Includes custom nginx configuration
- Final size: ~40MB

### Nginx Configuration

The production image uses nginx to:
- Serve static files with caching and compression
- Proxy `/api/*` requests to API container
- Proxy `/ws/*` WebSocket connections
- Handle React Router client-side routing
- Optimize with gzip compression

```nginx
location /api/ {
    proxy_pass http://api:8000/api/;
    # ... proxy headers
}

location /ws/ {
    proxy_pass http://api:8000/ws/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

### Environment Variables

The dashboard uses environment variables for configuration:

- `VITE_API_URL`: API server URL (default: `http://api:8000`)
- `VITE_WS_URL`: WebSocket URL (default: `ws://api:8000`)
- `VITE_DASH_USERS`: Dashboard users in `username:password:role` format (role is `admin` or `read_only`; old `username:password` format still works and defaults to `read_only`)

## 📊 Features

The dashboard provides:

1. **System Overview**
   - Active agents count
   - Job queue status
   - System health metrics

2. **Agent Management**
   - View all registered agents
   - Check agent status and queue depth
   - Agent details (role, goal, tools)
   - Chat with individual agents

3. **Observability**
   - View distributed traces
   - Monitor metrics and performance
   - Real-time logs via WebSocket
   - Token usage tracking

4. **Job Management**
   - Submit new jobs
   - Monitor job status
   - View results
   - Cancel running jobs

5. **Real-time Updates**
   - WebSocket for live logs
   - System event streaming
   - Agent status updates
6. **Admin Access Controls**
   - Role-based users (`admin`, `read_only`)
   - Admin-only Users page for creating/deleting dashboard users
   - Admin-only session visibility page (`/user-sessions`)

## 🔗 API Integration

The dashboard communicates with the Laddr API server:

### REST Endpoints
- `GET /api/agents` - List agents
- `GET /api/agents/{name}` - Get agent details
- `POST /api/agents/{name}/chat` - Chat with agent
- `GET /api/jobs` - List jobs
- `POST /api/jobs` - Submit job
- `GET /api/traces` - Get traces
- `GET /api/metrics` - Get metrics

### WebSocket Endpoints
- `WS /ws/logs/{agent}` - Stream agent logs
- `WS /ws/events` - Stream system events

## 🧪 Testing

```bash
# Run tests
npm test

# Run linting
npm run lint

# Type checking
npm run type-check

# Preview production build
npm run build
npm run preview
```

## 📦 Dependencies

### Core
- React 18.3 - UI framework
- React Router 6 - Client-side routing
- TypeScript - Type safety

### Data Fetching
- TanStack Query 5 - Server state management
- Axios - HTTP client

### UI Components
- Recharts - Data visualization
- Lucide React - Icons

### Build Tools
- Vite 5 - Build tool and dev server
- TypeScript - Type checking

## 🔄 Release Process

1. **Update version** in `package.json`
2. **Build image**: `./build-dashboard.sh v1.x.x`
3. **Test locally**: `docker run -p 5173:5173 laddr/dashboard:v1.x.x`
4. **Push to Docker Hub**: `docker push laddr/dashboard:v1.x.x`
5. **Tag as latest**: `docker push laddr/dashboard:latest`
6. **Update docs**: Note version in changelog

## 🐛 Troubleshooting

### Build fails
```bash
# Clean and rebuild
rm -rf node_modules dist
npm install
npm run build
```

### Docker image too large
- Check multi-stage build is working
- Verify `node_modules` not copied to final image
- Use `docker images` to check size

### API connection fails
- Verify nginx proxy configuration
- Check CORS settings in API server
- Ensure API container is running
- Check network connectivity between containers

## 📚 Resources

- [Vite Documentation](https://vitejs.dev/)
- [React Documentation](https://react.dev/)
- [Nginx Documentation](https://nginx.org/en/docs/)
- [Docker Multi-stage Builds](https://docs.docker.com/build/building/multi-stage/)

## 🤝 Contributing

For maintainers working on the dashboard:

1. Make changes in `src/`
2. Test locally with `npm run dev`
3. Build production image
4. Test Docker image locally
5. Push to Docker Hub
6. Update documentation

## 📄 License

Same as Laddr project license.

---

**Note**: This dashboard is designed to be distributed as a Docker image. Users should never need to modify or build it themselves. All customization is done via environment variables and API configuration.

# Homelab Media Architecture

This diagram shows how volumes are shared between media apps and how data flows through the system.

## Volume Sharing & Data Flow Diagram

```mermaid
flowchart TB
    subgraph User["👤 User"]
        UserBrowser["Web Browser"]
    end

    subgraph External["🌐 External Services"]
        NZBGeek["NZBGeek Indexer"]
        UsenetServer["Usenet Server"]
        TorrentTrackers["Torrent Trackers"]
    end

    subgraph Media["Media Management Apps"]
        direction TB
        Lidarr["🎵 Lidarr<br/>(Music)"]
        Radarr["🎬 Radarr<br/>(Movies)"]
        Sonarr["📺 Sonarr<br/>(TV Shows)"]
    end

    subgraph Downloaders["Download Clients"]
        direction TB
        SABnzbd["SABnzbd<br/>(Usenet)"]
        Deluge["Deluge<br/>(Torrents)"]
    end

    subgraph Processing["Processing"]
        Tdarr["🔄 Tdarr<br/>(Transcoding)"]
    end

    subgraph Players["Media Players"]
        direction TB
        Plex["📺 Plex"]
        Emby["📺 Emby"]
    end

    subgraph Volumes["📦 Storage Volumes"]
        direction TB
        
        subgraph LocalPath["Local-Path (Fast SSD)"]
            DelugeIncomplete["deluge-downloads-incomplete<br/>100Gi RWO"]
            SABIncomplete["sabnzbd-downloads-incomplete<br/>100Gi RWO"]
        end
        
        subgraph CephFS["CephFS (Network Storage)"]
            DownloadsComplete["downloads-complete<br/>Shared RWX"]
            MediaLibrary["media-library<br/>Shared RWX"]
        end
    end

    %% User interactions
    UserBrowser -->|"Browse & Select Content"| Media
    UserBrowser -->|"Watch Media"| Players

    %% Media management app workflows
    Media -->|"Search for Content"| NZBGeek
    Media -->|"Send Usenet Download"| SABnzbd
    Media -->|"Send Torrent Download"| Deluge

    %% Downloader workflows
    SABnzbd -->|"Fetch NZB Files"| UsenetServer
    Deluge -->|"Fetch Torrent Files"| TorrentTrackers
    
    %% Volume mounts - Downloaders
    SABnzbd -.->|"Mount RWO"| SABIncomplete
    Deluge -.->|"Mount RWO"| DelugeIncomplete
    SABnzbd -.->|"Mount RWX"| DownloadsComplete
    Deluge -.->|"Mount RWX"| DownloadsComplete
    
    %% Download process
    SABIncomplete -->|"Download Complete<br/>Move Files"| DownloadsComplete
    DelugeIncomplete -->|"Download Complete<br/>Move Files"| DownloadsComplete
    
    %% Processing workflow
    DownloadsComplete -->|"Watch for New Files"| Tdarr
    Tdarr -->|"Transcode & Move"| MediaLibrary
    
    %% Media management mounts
    Media -.->|"Mount RWX"| DownloadsComplete
    Media -.->|"Mount RWX"| MediaLibrary
    
    %% Processing mounts
    Tdarr -.->|"Mount RWX"| DownloadsComplete
    Tdarr -.->|"Mount RWX"| MediaLibrary
    
    %% Player mounts
    Players -.->|"Mount RWX"| MediaLibrary
    MediaLibrary -->|"Detect New Media<br/>Refresh Library"| Players

    %% Styling
    classDef userClass fill:#e1f5ff,stroke:#01579b,stroke-width:2px
    classDef externalClass fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef mediaClass fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef downloadClass fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px
    classDef processClass fill:#fff9c4,stroke:#f57f17,stroke-width:2px
    classDef playerClass fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    classDef localClass fill:#ffebee,stroke:#c62828,stroke-width:2px
    classDef cephClass fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    
    class User,UserBrowser userClass
    class NZBGeek,UsenetServer,TorrentTrackers externalClass
    class Lidarr,Radarr,Sonarr mediaClass
    class SABnzbd,Deluge downloadClass
    class Tdarr processClass
    class Plex,Emby playerClass
    class DelugeIncomplete,SABIncomplete localClass
    class DownloadsComplete,MediaLibrary cephClass
```

## Volume Mount Summary

### Apps and Their Volume Mounts

| App | Config | Downloads Incomplete | Downloads Complete | Media Library |
|-----|--------|---------------------|-------------------|---------------|
| **Lidarr** | ✅ lidarr-config (CephFS) | ❌ | ✅ RWX | ✅ RWX |
| **Radarr** | ✅ radarr-config (CephFS) | ❌ | ✅ RWX | ✅ RWX |
| **Sonarr** | ✅ sonarr-config (CephFS) | ❌ | ✅ RWX | ✅ RWX |
| **SABnzbd** | ✅ sabnzbd-config (CephFS) | ✅ sabnzbd-downloads-incomplete (Local-Path, RWO) | ✅ RWX | ❌ |
| **Deluge** | ✅ deluge-config (CephFS) | ✅ deluge-downloads-incomplete (Local-Path, RWO) | ✅ RWX | ❌ |
| **Tdarr** | ✅ tdarr-config (CephFS) | ❌ | ✅ RWX | ✅ RWX |
| **Plex** | ✅ plex-config (CephFS) | ❌ | ❌ | ✅ RWX |
| **Emby** | ✅ emby-config (CephFS) | ❌ | ❌ | ✅ RWX |

### Volume Types

- **RWO**: ReadWriteOnce (single node access)
- **RWX**: ReadWriteMany (multi-node access)
- **Local-Path**: Fast local SSD storage for active downloads
- **CephFS**: Network-attached storage for shared access

## Data Flow Process

1. **User Request**: User browses Lidarr/Radarr/Sonarr and selects content to download
2. **Content Search**: App searches NZBGeek indexer for matching content
3. **Download Request**: 
   - Usenet downloads → SABnzbd
   - Torrent downloads → Deluge
4. **Active Download**: Files downloaded to fast local-path volumes:
   - `/downloads/incomplete` (SABnzbd or Deluge)
5. **Download Complete**: Files moved to shared CephFS volume:
   - `downloads-complete` (mounted at `/downloads/complete`)
6. **Processing**: Tdarr watches `downloads-complete`:
   - Transcodes files to meet quality/codec requirements
   - Moves processed files to `media-library`
7. **Media Detection**: Plex and Emby watch `media-library`:
   - Automatically detect new content
   - Refresh library and make available to users

## Storage Strategy

### Why Two-Stage Download Storage?

1. **Fast Local Storage** (`local-path`):
   - Active downloads benefit from fast SSD I/O
   - Each downloader gets its own 100Gi RWO volume
   - No network latency during active downloads

2. **Shared Network Storage** (`CephFS`):
   - Completed downloads on `downloads-complete` for processing
   - Final media on `media-library` for playback
   - Accessible from all apps across all nodes
   - Persistent and backed up

This architecture ensures optimal performance while maintaining data accessibility across all media services.


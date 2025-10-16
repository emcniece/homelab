# Homelab Media Architecture

This document shows how data flows through the media apps and how storage volumes are shared between them.

## Data Flow Diagram

This diagram shows how content moves through the system from user request to final playback.

```mermaid
flowchart LR
    User["👤 User"] -->|Browse & Request Content| Media["Media Apps<br/>Lidarr/Radarr/Sonarr"]
    Media -->|Search| Indexer["NZBGeek<br/>Indexer"]
    Media -->|Send Download Request| Downloaders["Downloaders<br/>SABnzbd/Deluge"]
    
    Downloaders -->|Download| External["External Sources<br/>Usenet/Torrents"]
    Downloaders -->|Save to| Incomplete["Local Fast Storage<br/>downloads-incomplete"]
    Incomplete -->|Move When Complete| Complete["Shared Storage<br/>downloads-complete"]
    
    Complete -->|Watch & Process| Tdarr["Tdarr<br/>Transcoding"]
    Tdarr -->|Move Processed| Library["Shared Storage<br/>media-library"]
    
    Library -->|Scan & Index| Players["Media Players<br/>Plex/Emby"]
    Players -->|Stream to| User

    %% Styling
    classDef userClass fill:#e1f5ff,stroke:#01579b,stroke-width:2px
    classDef appClass fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef downloadClass fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px
    classDef storageClass fill:#fff9c4,stroke:#f57f17,stroke-width:2px
    classDef externalClass fill:#fff3e0,stroke:#e65100,stroke-width:2px
    
    class User userClass
    class Media,Players,Tdarr appClass
    class Downloaders downloadClass
    class Incomplete,Complete,Library storageClass
    class Indexer,External externalClass
```

## Volume Sharing Diagram

This diagram shows which storage volumes are mounted by each application.

```mermaid
flowchart LR
    subgraph Downloaders["Download Clients"]
        direction TB
        SABnzbd["📥 SABnzbd"]
        Deluge["📥 Deluge"]
    end

    subgraph LocalStorage["Local-Path Storage<br/>(Fast SSD)"]
        direction TB
        SABIncomplete["sabnzbd-downloads-incomplete<br/>100Gi RWO"]
        DelugeIncomplete["deluge-downloads-incomplete<br/>100Gi RWO"]
    end

    subgraph SharedDownloads["downloads-complete<br/>(CephFS RWX)"]
        direction TB
        DCVolume["Shared download<br/>completion area"]
    end

    subgraph Processing["Processing"]
        direction TB
        Tdarr["🔄 Tdarr"]
    end

    subgraph MediaLib["media-library<br/>(CephFS RWX)"]
        direction TB
        MLVolume["Final processed<br/>media storage"]
    end

    subgraph MediaManagement["Media Management"]
        direction TB
        Lidarr["🎵 Lidarr"]
        Radarr["🎬 Radarr"]
        Sonarr["📺 Sonarr"]
    end

    subgraph Players["Media Players"]
        direction TB
        Plex["📺 Plex"]
        Emby["📺 Emby"]
    end

    %% Downloader connections
    SABnzbd -.-> SABIncomplete
    Deluge -.-> DelugeIncomplete
    SABnzbd -.-> SharedDownloads
    Deluge -.-> SharedDownloads

    %% Processing connections
    SharedDownloads -.-> Processing
    Processing -.-> MediaLib

    %% Media management connections
    MediaLib -.-> MediaManagement

    %% Player connections
    MediaLib -.-> Players

    %% Styling
    classDef downloadAppClass fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px
    classDef localVolumeClass fill:#ffebee,stroke:#c62828,stroke-width:2px
    classDef sharedVolumeClass fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    classDef mediaAppClass fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef processAppClass fill:#fff9c4,stroke:#f57f17,stroke-width:2px
    classDef playerAppClass fill:#fce4ec,stroke:#880e4f,stroke-width:2px

    class SABnzbd,Deluge downloadAppClass
    class SABIncomplete,DelugeIncomplete localVolumeClass
    class SharedDownloads,MediaLib sharedVolumeClass
    class Lidarr,Radarr,Sonarr mediaAppClass
    class Tdarr processAppClass
    class Plex,Emby playerAppClass
```

## Volume Mount Summary

### Apps and Their Volume Mounts

| App | Config | Downloads Incomplete | Downloads Complete | Media Library |
|-----|--------|---------------------|-------------------|---------------|
| **Lidarr** | ✅ lidarr-config (CephFS) | ❌ | ❌ | ✅ RWX |
| **Radarr** | ✅ radarr-config (CephFS) | ❌ | ❌ | ✅ RWX |
| **Sonarr** | ✅ sonarr-config (CephFS) | ❌ | ❌ | ✅ RWX |
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


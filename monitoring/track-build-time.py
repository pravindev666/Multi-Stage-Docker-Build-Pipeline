"""
Docker Build Time Tracker
Monitors and tracks Docker build times, cache hit rates, and build performance metrics
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


class BuildTimeTracker:
    """Track Docker build times and performance metrics"""
    
    def __init__(self, data_file="build-history.json"):
        self.data_file = Path(data_file)
        self.history = self._load_history()
    
    def _load_history(self):
        """Load historical build data from JSON file"""
        if self.data_file.exists():
            with open(self.data_file, 'r') as f:
                return json.load(f)
        return {"builds": []}
    
    def _save_history(self):
        """Save build history to JSON file"""
        with open(self.data_file, 'w') as f:
            json.dump(self.history, f, indent=2)
    
    def format_duration(self, seconds):
        """Convert seconds to human-readable duration"""
        if seconds < 60:
            return f"{seconds:.2f}s"
        elif seconds < 3600:
            minutes = int(seconds // 60)
            secs = int(seconds % 60)
            return f"{minutes}m {secs}s"
        else:
            hours = int(seconds // 3600)
            minutes = int((seconds % 3600) // 60)
            return f"{hours}h {minutes}m"
    
    def build_image(self, dockerfile, context, image_name, build_args=None, no_cache=False):
        """Build Docker image and measure time"""
        print(f"\nBuilding image: {image_name}")
        print(f"Dockerfile: {dockerfile}")
        print(f"Context: {context}")
        print(f"No cache: {no_cache}")
        print("-" * 60)
        
        # Prepare build command
        cmd = [
            'docker', 'build',
            '-f', dockerfile,
            '-t', image_name,
            context
        ]
        
        if no_cache:
            cmd.insert(2, '--no-cache')
        
        if build_args:
            for key, value in build_args.items():
                cmd.extend(['--build-arg', f'{key}={value}'])
        
        # Start timer
        start_time = time.time()
        
        # Execute build
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True
            )
            
            end_time = time.time()
            duration = end_time - start_time
            
            # Parse build output for cache hits
            output = result.stdout
            cache_hits = output.count('CACHED')
            total_steps = output.count('Step ')
            cache_hit_rate = (cache_hits / total_steps * 100) if total_steps > 0 else 0
            
            print(f"✓ Build completed in {self.format_duration(duration)}")
            print(f"  Cache hits: {cache_hits}/{total_steps} ({cache_hit_rate:.1f}%)")
            
            return {
                'success': True,
                'duration': duration,
                'cache_hits': cache_hits,
                'total_steps': total_steps,
                'cache_hit_rate': cache_hit_rate,
                'output': output
            }
            
        except subprocess.CalledProcessError as e:
            end_time = time.time()
            duration = end_time - start_time
            
            print(f"✗ Build failed after {self.format_duration(duration)}")
            print(f"Error: {e.stderr}")
            
            return {
                'success': False,
                'duration': duration,
                'error': e.stderr
            }
    
    def get_image_size(self, image_name):
        """Get size of Docker image in bytes"""
        try:
            result = subprocess.run(
                ['docker', 'inspect', '--format={{.Size}}', image_name],
                capture_output=True,
                text=True,
                check=True
            )
            return int(result.stdout.strip())
        except Exception:
            return None
    
    def get_human_readable_size(self, size_bytes):
        """Convert bytes to human-readable format"""
        if size_bytes is None:
            return "N/A"
        
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size_bytes < 1024.0:
                return f"{size_bytes:.2f} {unit}"
            size_bytes /= 1024.0
        return f"{size_bytes:.2f} TB"
    
    def track_build(self, dockerfile, context, image_name, build_type="multi-stage", 
                   commit_sha=None, no_cache=False, build_args=None):
        """Track a complete build with all metrics"""
        
        # Perform build
        build_result = self.build_image(dockerfile, context, image_name, build_args, no_cache)
        
        if not build_result['success']:
            print("\nBuild failed - not recording metrics")
            return None
        
        # Get image size
        image_size = self.get_image_size(image_name)
        
        # Create build entry
        entry = {
            "timestamp": datetime.utcnow().isoformat(),
            "commit": commit_sha or "unknown",
            "build_type": build_type,
            "image_name": image_name,
            "dockerfile": dockerfile,
            "no_cache": no_cache,
            "duration_seconds": round(build_result['duration'], 2),
            "duration_human": self.format_duration(build_result['duration']),
            "cache_hits": build_result['cache_hits'],
            "total_steps": build_result['total_steps'],
            "cache_hit_rate": round(build_result['cache_hit_rate'], 2),
            "image_size_bytes": image_size,
            "image_size_human": self.get_human_readable_size(image_size)
        }
        
        self.history["builds"].append(entry)
        self._save_history()
        
        return entry
    
    def print_build_summary(self, entry):
        """Print summary of current build"""
        print("\n" + "="*70)
        print("Build Summary")
        print("="*70)
        print(f"Timestamp:       {entry['timestamp']}")
        print(f"Commit:          {entry['commit']}")
        print(f"Build Type:      {entry['build_type']}")
        print(f"Image:           {entry['image_name']}")
        print()
        print(f"Duration:        {entry['duration_human']}")
        print(f"Image Size:      {entry['image_size_human']}")
        print(f"Cache Hits:      {entry['cache_hits']}/{entry['total_steps']} ({entry['cache_hit_rate']}%)")
        print(f"No Cache Build:  {'Yes' if entry['no_cache'] else 'No'}")
        print("="*70 + "\n")
    
    def generate_performance_report(self):
        """Generate performance report from historical data"""
        if not self.history["builds"]:
            print("No historical data available")
            return
        
        builds = self.history["builds"]
        
        print("\n" + "="*80)
        print("Build Performance Report")
        print("="*80)
        print(f"Total Builds Tracked: {len(builds)}")
        print()
        
        # Separate by build type
        multi_stage = [b for b in builds if b['build_type'] == 'multi-stage']
        single_stage = [b for b in builds if b['build_type'] == 'single-stage']
        
        # Calculate statistics for multi-stage
        if multi_stage:
            print("Multi-Stage Builds:")
            print("-" * 80)
            avg_duration = sum(b['duration_seconds'] for b in multi_stage) / len(multi_stage)
            avg_cache_rate = sum(b['cache_hit_rate'] for b in multi_stage) / len(multi_stage)
            cached_builds = [b for b in multi_stage if not b['no_cache']]
            no_cache_builds = [b for b in multi_stage if b['no_cache']]
            
            print(f"  Total builds:           {len(multi_stage)}")
            print(f"  Average duration:       {self.format_duration(avg_duration)}")
            print(f"  Average cache hit rate: {avg_cache_rate:.1f}%")
            
            if cached_builds:
                avg_cached = sum(b['duration_seconds'] for b in cached_builds) / len(cached_builds)
                print(f"  With cache:             {self.format_duration(avg_cached)}")
            
            if no_cache_builds:
                avg_no_cache = sum(b['duration_seconds'] for b in no_cache_builds) / len(no_cache_builds)
                print(f"  Without cache:          {self.format_duration(avg_no_cache)}")
            
            print()
        
        # Calculate statistics for single-stage
        if single_stage:
            print("Single-Stage Builds:")
            print("-" * 80)
            avg_duration = sum(b['duration_seconds'] for b in single_stage) / len(single_stage)
            
            print(f"  Total builds:           {len(single_stage)}")
            print(f"  Average duration:       {self.format_duration(avg_duration)}")
            print()
        
        # Compare if both exist
        if multi_stage and single_stage:
            multi_avg = sum(b['duration_seconds'] for b in multi_stage) / len(multi_stage)
            single_avg = sum(b['duration_seconds'] for b in single_stage) / len(single_stage)
            
            if single_avg > multi_avg:
                improvement = ((single_avg - multi_avg) / single_avg) * 100
                time_saved = single_avg - multi_avg
                print("Build Time Comparison:")
                print("-" * 80)
                print(f"  Multi-stage is {improvement:.1f}% faster")
                print(f"  Average time saved: {self.format_duration(time_saved)}")
                print()
        
        # Show last 5 builds
        print("Recent Builds (Last 5):")
        print("-" * 80)
        print(f"{'Date':<20} {'Type':<15} {'Duration':<12} {'Cache':<10} {'Size':<12}")
        print("-" * 80)
        
        for build in builds[-5:]:
            date = build['timestamp'][:19]
            build_type = build['build_type']
            duration = build['duration_human']
            cache = f"{build['cache_hit_rate']:.1f}%"
            size = build['image_size_human']
            
            print(f"{date:<20} {build_type:<15} {duration:<12} {cache:<10} {size:<12}")
        
        print("="*80 + "\n")
    
    def compare_builds(self):
        """Compare multi-stage vs single-stage builds"""
        builds = self.history["builds"]
        
        multi_stage = [b for b in builds if b['build_type'] == 'multi-stage']
        single_stage = [b for b in builds if b['build_type'] == 'single-stage']
        
        if not multi_stage or not single_stage:
            print("Need both multi-stage and single-stage builds for comparison")
            return
        
        print("\n" + "="*70)
        print("Multi-Stage vs Single-Stage Comparison")
        print("="*70)
        
        # Duration comparison
        multi_avg_duration = sum(b['duration_seconds'] for b in multi_stage) / len(multi_stage)
        single_avg_duration = sum(b['duration_seconds'] for b in single_stage) / len(single_stage)
        duration_improvement = ((single_avg_duration - multi_avg_duration) / single_avg_duration) * 100
        
        print("\nBuild Duration:")
        print(f"  Multi-Stage:  {self.format_duration(multi_avg_duration)}")
        print(f"  Single-Stage: {self.format_duration(single_avg_duration)}")
        print(f"  Improvement:  {duration_improvement:.1f}% faster")
        
        # Size comparison
        multi_avg_size = sum(b['image_size_bytes'] for b in multi_stage if b['image_size_bytes']) / len([b for b in multi_stage if b['image_size_bytes']])
        single_avg_size = sum(b['image_size_bytes'] for b in single_stage if b['image_size_bytes']) / len([b for b in single_stage if b['image_size_bytes']])
        size_reduction = ((single_avg_size - multi_avg_size) / single_avg_size) * 100
        
        print("\nImage Size:")
        print(f"  Multi-Stage:  {self.get_human_readable_size(multi_avg_size)}")
        print(f"  Single-Stage: {self.get_human_readable_size(single_avg_size)}")
        print(f"  Reduction:    {size_reduction:.1f}% smaller")
        
        print("="*70 + "\n")
    
    def export_csv(self, filename="build-history.csv"):
        """Export history to CSV format"""
        if not self.history["builds"]:
            print("No data to export")
            return
        
        with open(filename, 'w') as f:
            f.write("timestamp,commit,build_type,image_name,duration_seconds,cache_hits,total_steps,cache_hit_rate,image_size_bytes,no_cache\n")
            
            for build in self.history["builds"]:
                f.write(f"{build['timestamp']},")
                f.write(f"{build['commit']},")
                f.write(f"{build['build_type']},")
                f.write(f"{build['image_name']},")
                f.write(f"{build['duration_seconds']},")
                f.write(f"{build['cache_hits']},")
                f.write(f"{build['total_steps']},")
                f.write(f"{build['cache_hit_rate']},")
                f.write(f"{build.get('image_size_bytes', 0)},")
                f.write(f"{build['no_cache']}\n")
        
        print(f"Data exported to {filename}")


def main():
    """Main execution function"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Track Docker build times")
    parser.add_argument(
        '--dockerfile',
        default='app/Dockerfile.multi-stage',
        help='Path to Dockerfile'
    )
    parser.add_argument(
        '--context',
        default='app',
        help='Build context path'
    )
    parser.add_argument(
        '--image',
        default='multi-stage-app:latest',
        help='Image name and tag'
    )
    parser.add_argument(
        '--type',
        choices=['multi-stage', 'single-stage'],
        default='multi-stage',
        help='Build type'
    )
    parser.add_argument(
        '--commit',
        help='Git commit SHA'
    )
    parser.add_argument(
        '--no-cache',
        action='store_true',
        help='Build without cache'
    )
    parser.add_argument(
        '--report',
        action='store_true',
        help='Generate performance report'
    )
    parser.add_argument(
        '--compare',
        action='store_true',
        help='Compare multi-stage vs single-stage'
    )
    parser.add_argument(
        '--export-csv',
        action='store_true',
        help='Export data to CSV'
    )
    parser.add_argument(
        '--data-file',
        default='build-history.json',
        help='Path to data file'
    )
    
    args = parser.parse_args()
    
    # Initialize tracker
    tracker = BuildTimeTracker(data_file=args.data_file)
    
    # Generate report if requested
    if args.report:
        tracker.generate_performance_report()
        return
    
    # Compare builds if requested
    if args.compare:
        tracker.compare_builds()
        return
    
    # Export CSV if requested
    if args.export_csv:
        tracker.export_csv()
        return
    
    # Track build
    print(f"Tracking {args.type} build...")
    entry = tracker.track_build(
        dockerfile=args.dockerfile,
        context=args.context,
        image_name=args.image,
        build_type=args.type,
        commit_sha=args.commit,
        no_cache=args.no_cache
    )
    
    if entry:
        tracker.print_build_summary(entry)
        print(f"Data saved to {args.data_file}")
    else:
        print("Build tracking failed")
        sys.exit(1)


if __name__ == "__main__":
    main()

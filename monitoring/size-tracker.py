"""
Docker Image Size Tracker
Monitors and tracks Docker image sizes over time, comparing multi-stage vs single-stage builds
"""

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path


class SizeTracker:
    """Track Docker image sizes and generate reports"""
    
    def __init__(self, data_file="size-history.json"):
        self.data_file = Path(data_file)
        self.history = self._load_history()
    
    def _load_history(self):
        """Load historical size data from JSON file"""
        if self.data_file.exists():
            with open(self.data_file, 'r') as f:
                return json.load(f)
        return {"entries": []}
    
    def _save_history(self):
        """Save size history to JSON file"""
        with open(self.data_file, 'w') as f:
            json.dump(self.history, f, indent=2)
    
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
        except subprocess.CalledProcessError:
            print(f"Error: Image {image_name} not found")
            return None
        except Exception as e:
            print(f"Error getting image size: {e}")
            return None
    
    def get_human_readable_size(self, size_bytes):
        """Convert bytes to human-readable format"""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size_bytes < 1024.0:
                return f"{size_bytes:.2f} {unit}"
            size_bytes /= 1024.0
        return f"{size_bytes:.2f} TB"
    
    def track_images(self, multi_stage_image, single_stage_image, commit_sha=None):
        """Track sizes of both multi-stage and single-stage images"""
        multi_size = self.get_image_size(multi_stage_image)
        single_size = self.get_image_size(single_stage_image)
        
        if multi_size is None or single_size is None:
            print("Error: Could not retrieve image sizes")
            return False
        
        # Calculate savings
        size_reduction = single_size - multi_size
        reduction_percent = (size_reduction / single_size) * 100
        
        # Create entry
        entry = {
            "timestamp": datetime.utcnow().isoformat(),
            "commit": commit_sha or "unknown",
            "multi_stage": {
                "image": multi_stage_image,
                "size_bytes": multi_size,
                "size_human": self.get_human_readable_size(multi_size)
            },
            "single_stage": {
                "image": single_stage_image,
                "size_bytes": single_size,
                "size_human": self.get_human_readable_size(single_size)
            },
            "reduction": {
                "bytes": size_reduction,
                "human": self.get_human_readable_size(size_reduction),
                "percent": round(reduction_percent, 2)
            }
        }
        
        self.history["entries"].append(entry)
        self._save_history()
        
        return entry
    
    def print_current_comparison(self, entry):
        """Print current size comparison"""
        print("\n" + "="*60)
        print("Docker Image Size Comparison")
        print("="*60)
        print(f"Timestamp: {entry['timestamp']}")
        print(f"Commit: {entry['commit']}")
        print()
        print(f"Multi-Stage Image:  {entry['multi_stage']['size_human']:>15}")
        print(f"Single-Stage Image: {entry['single_stage']['size_human']:>15}")
        print("-" * 60)
        print(f"Size Reduction:     {entry['reduction']['human']:>15} ({entry['reduction']['percent']}%)")
        print("="*60 + "\n")
    
    def generate_trend_report(self):
        """Generate trend report from historical data"""
        if not self.history["entries"]:
            print("No historical data available")
            return
        
        print("\n" + "="*80)
        print("Size Trend Report")
        print("="*80)
        print(f"Total Builds Tracked: {len(self.history['entries'])}")
        print()
        
        # Calculate averages
        total_multi = sum(e["multi_stage"]["size_bytes"] for e in self.history["entries"])
        total_single = sum(e["single_stage"]["size_bytes"] for e in self.history["entries"])
        count = len(self.history["entries"])
        
        avg_multi = total_multi / count
        avg_single = total_single / count
        avg_reduction = ((avg_single - avg_multi) / avg_single) * 100
        
        print(f"Average Multi-Stage Size:  {self.get_human_readable_size(avg_multi)}")
        print(f"Average Single-Stage Size: {self.get_human_readable_size(avg_single)}")
        print(f"Average Reduction:         {avg_reduction:.2f}%")
        print()
        
        # Show last 5 entries
        print("Recent History (Last 5 Builds):")
        print("-" * 80)
        print(f"{'Date':<20} {'Commit':<12} {'Multi-Stage':<15} {'Single-Stage':<15} {'Reduction':<10}")
        print("-" * 80)
        
        for entry in self.history["entries"][-5:]:
            date = entry["timestamp"][:19]
            commit = entry["commit"][:10]
            multi = entry["multi_stage"]["size_human"]
            single = entry["single_stage"]["size_human"]
            reduction = f"{entry['reduction']['percent']}%"
            
            print(f"{date:<20} {commit:<12} {multi:<15} {single:<15} {reduction:<10}")
        
        print("="*80 + "\n")
    
    def export_csv(self, filename="size-history.csv"):
        """Export history to CSV format"""
        if not self.history["entries"]:
            print("No data to export")
            return
        
        with open(filename, 'w') as f:
            f.write("timestamp,commit,multi_stage_bytes,multi_stage_human,single_stage_bytes,single_stage_human,reduction_bytes,reduction_percent\n")
            
            for entry in self.history["entries"]:
                f.write(f"{entry['timestamp']},")
                f.write(f"{entry['commit']},")
                f.write(f"{entry['multi_stage']['size_bytes']},")
                f.write(f"{entry['multi_stage']['size_human']},")
                f.write(f"{entry['single_stage']['size_bytes']},")
                f.write(f"{entry['single_stage']['size_human']},")
                f.write(f"{entry['reduction']['bytes']},")
                f.write(f"{entry['reduction']['percent']}\n")
        
        print(f"Data exported to {filename}")


def main():
    """Main execution function"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Track Docker image sizes")
    parser.add_argument(
        '--multi-stage',
        default='multi-stage-app:latest',
        help='Multi-stage image name (default: multi-stage-app:latest)'
    )
    parser.add_argument(
        '--single-stage',
        default='single-stage-app:latest',
        help='Single-stage image name (default: single-stage-app:latest)'
    )
    parser.add_argument(
        '--commit',
        help='Git commit SHA'
    )
    parser.add_argument(
        '--report',
        action='store_true',
        help='Generate trend report'
    )
    parser.add_argument(
        '--export-csv',
        action='store_true',
        help='Export data to CSV'
    )
    parser.add_argument(
        '--data-file',
        default='size-history.json',
        help='Path to data file (default: size-history.json)'
    )
    
    args = parser.parse_args()
    
    # Initialize tracker
    tracker = SizeTracker(data_file=args.data_file)
    
    # Generate report if requested
    if args.report:
        tracker.generate_trend_report()
        return
    
    # Export CSV if requested
    if args.export_csv:
        tracker.export_csv()
        return
    
    # Track current images
    print("Tracking Docker image sizes...")
    entry = tracker.track_images(
        args.multi_stage,
        args.single_stage,
        args.commit
    )
    
    if entry:
        tracker.print_current_comparison(entry)
        print(f"Data saved to {args.data_file}")
    else:
        print("Failed to track image sizes")
        sys.exit(1)


if __name__ == "__main__":
    main()

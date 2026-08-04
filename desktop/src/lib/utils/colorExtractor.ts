/**
 * 从封面图片提取主色调
 * 将图片绘制到 canvas，采样像素取平均色
 */

export function extractColorFromDataUrl(dataUrl: string): Promise<string> {
	return new Promise((resolve, reject) => {
		const img = new Image();
		img.crossOrigin = 'anonymous';
		img.onload = () => {
			const canvas = document.createElement('canvas');
			const size = 50; // 缩小到 50x50 提速
			canvas.width = size;
			canvas.height = size;
			const ctx = canvas.getContext('2d')!;
			ctx.drawImage(img, 0, 0, size, size);

			const imageData = ctx.getImageData(0, 0, size, size);
			const data = imageData.data;
			let r = 0, g = 0, b = 0, count = 0;

			// 每隔 2 个像素采样一次
			for (let i = 0; i < data.length; i += 8) {
				// 跳过接近黑色或白色的像素
				const pr = data[i], pg = data[i + 1], pb = data[i + 2];
				const brightness = (pr + pg + pb) / 3;
				if (brightness < 30 || brightness > 225) continue;
				r += pr; g += pg; b += pb; count++;
			}

			if (count === 0) {
				// 如果全部被跳过，取整体平均
				for (let i = 0; i < data.length; i += 4) {
					r += data[i]; g += data[i + 1]; b += data[i + 2]; count++;
				}
			}

			r = Math.round(r / count);
			g = Math.round(g / count);
			b = Math.round(b / count);

			// 确保颜色不太暗也不太亮
			const brightness = (r + g + b) / 3;
			if (brightness < 60) { r = Math.min(255, r + 40); g = Math.min(255, g + 40); b = Math.min(255, b + 40); }
			if (brightness > 200) { r = Math.max(0, r - 30); g = Math.max(0, g - 30); b = Math.max(0, b - 30); }

			const hex = `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
			resolve(hex);
		};
		img.onerror = () => reject(new Error('Failed to load image'));
		img.src = dataUrl;
	});
}


